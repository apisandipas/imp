//! A text buffer: a rope plus a file path and snapshot-based undo.
//!
//! Positions are char offsets into the whole text. Line/column conversions are
//! provided for the editing layer, which decides what the positions mean.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

use ropey::Rope;

use crate::fileio::{self, FileFormat};

#[derive(Debug, Default)]
pub struct Buffer {
    text: Rope,
    path: Option<PathBuf>,
    /// Name of a buffer with no file, such as "*messages*".
    name: Option<String>,
    modified: bool,
    // Rope clones share structure, so a snapshot is cheap.
    undo: Vec<Rope>,
    redo: Vec<Rope>,
    /// Whether the text changed since the last undo point, so a boundary
    /// knows whether to record one without comparing ropes.
    dirty: bool,
    /// Named positions that move with the text around them. Vim's marks,
    /// the jump list and anything else Scheme wants kept in place.
    marks: HashMap<String, usize>,
    /// Goes up with every change (and undo/redo), so watchers can tell
    /// whether the text changed without comparing it.
    version: u64,
    /// How the file was stored, to write it back the same way.
    format: FileFormat,
    /// The file's modification time and size when last read or written,
    /// to notice changes made outside the editor.
    disk: Option<(std::time::SystemTime, u64)>,
    /// Keep the previous version as `FILE~` when saving.
    pub backup: bool,
    /// Edits since a parser last looked, when something asked to track
    /// them (a syntax tree; see `track_edits`).
    edits: Option<Vec<Edit>>,
}

/// One change to the text, in the terms a tree-sitter parser wants:
/// byte offsets, and (row, byte column) points.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edit {
    Change {
        start_byte: usize,
        old_end_byte: usize,
        new_end_byte: usize,
        start: (usize, usize),
        old_end: (usize, usize),
        new_end: (usize, usize),
    },
    /// The whole text was replaced (undo, redo, reload).
    Reset,
}

impl Buffer {
    pub fn from_text(text: &str) -> Self {
        Self {
            text: Rope::from_str(text),
            ..Self::default()
        }
    }

    /// Opens `path`, or starts an empty buffer for it if the file doesn't
    /// exist. Line endings and encoding are noted to write back the same.
    pub fn open(path: &Path) -> io::Result<Self> {
        let (text, format) = read_file(path)?;
        Ok(Self {
            text: Rope::from_str(&text),
            path: Some(path.to_path_buf()),
            format,
            disk: fileio::stamp(path),
            ..Self::default()
        })
    }

    /// Saves to the buffer's file, atomically (see `fileio::write_atomic`).
    pub fn save(&mut self) -> io::Result<()> {
        let path = self
            .path
            .clone()
            .ok_or_else(|| io::Error::other("buffer has no file name"))?;
        let bytes = fileio::encode(&self.text.to_string(), self.format)?;
        fileio::write_atomic(&path, &bytes, self.backup)?;
        self.modified = false;
        self.disk = fileio::stamp(&path);
        Ok(())
    }

    /// Writes the text to `path` without changing the buffer's own file.
    pub fn write_to(&self, path: &Path) -> io::Result<()> {
        let bytes = fileio::encode(&self.text.to_string(), self.format)?;
        fileio::write_atomic(path, &bytes, false)
    }

    pub fn format(&self) -> FileFormat {
        self.format
    }

    pub fn set_format(&mut self, format: FileFormat) {
        if format != self.format {
            self.format = format;
            // Saving would now write different bytes.
            self.modified = true;
        }
    }

    /// Whether the file changed on disk since it was last read or written
    /// here (including appearing or disappearing).
    pub fn changed_on_disk(&self) -> bool {
        match &self.path {
            Some(path) => fileio::stamp(path) != self.disk,
            None => false,
        }
    }

    /// Accepts the file on disk as it is now, as `:w!` over a changed file
    /// will.
    pub fn forget_disk_change(&mut self) {
        if let Some(path) = &self.path {
            self.disk = fileio::stamp(path);
        }
    }

    pub fn set_path(&mut self, path: Option<PathBuf>) {
        self.path = path;
    }

    pub fn set_name(&mut self, name: Option<String>) {
        self.name = name;
    }

    /// The name to show: the file's path, the buffer's own name, or
    /// "[No Name]".
    pub fn display_name(&self) -> String {
        match (&self.path, &self.name) {
            (Some(path), _) => path.display().to_string(),
            (None, Some(name)) => name.clone(),
            (None, None) => "[No Name]".to_string(),
        }
    }

    /// Reads the file again, discarding changes. Undo history is kept, so
    /// the reload itself can be undone.
    pub fn reload(&mut self) -> io::Result<()> {
        let path = self
            .path
            .clone()
            .ok_or_else(|| io::Error::other("buffer has no file name"))?;
        let (text, format) = read_file(&path)?;
        self.format = format;
        self.disk = fileio::stamp(&path);
        self.undo_boundary();
        let len = self.len();
        self.text.remove(0..len);
        self.text.insert(0, &text);
        self.version += 1;
        self.record_reset();
        self.dirty = true;
        self.modified = false;
        Ok(())
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Marks the text as matching what is on disk, as after a save.
    pub fn set_unmodified(&mut self) {
        self.modified = false;
    }

    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn is_modified(&self) -> bool {
        self.modified
    }

    pub fn text(&self) -> String {
        self.text.to_string()
    }

    /// Number of chars in the buffer.
    pub fn len(&self) -> usize {
        self.text.len_chars()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The chars in `start..end`, clamped to the buffer.
    pub fn slice(&self, start: usize, end: usize) -> String {
        let end = end.min(self.len());
        let start = start.min(end);
        self.text.slice(start..end).to_string()
    }

    /// The text as a rope, for scanning without copying it.
    pub fn rope(&self) -> &Rope {
        &self.text
    }

    pub fn char_at(&self, offset: usize) -> Option<char> {
        (offset < self.len()).then(|| self.text.char(offset))
    }

    /// Number of lines. A trailing newline does not start an extra line.
    pub fn line_count(&self) -> usize {
        let n = self.text.len_lines();
        if n > 1 && self.text.line(n - 1).len_chars() == 0 {
            n - 1
        } else {
            n
        }
    }

    /// Length of `line` in chars, not counting its line break.
    pub fn line_len(&self, line: usize) -> usize {
        if line >= self.text.len_lines() {
            return 0;
        }
        let slice = self.text.line(line);
        let len = slice.len_chars();
        let mut break_len = 0;
        if len > 0 && slice.char(len - 1) == '\n' {
            break_len = 1;
            if len > 1 && slice.char(len - 2) == '\r' {
                break_len = 2;
            }
        }
        len - break_len
    }

    pub fn line_text(&self, line: usize) -> String {
        if line >= self.text.len_lines() {
            return String::new();
        }
        let start = self.text.line_to_char(line);
        self.text
            .slice(start..start + self.line_len(line))
            .to_string()
    }

    pub fn offset_to_line(&self, offset: usize) -> usize {
        self.text.char_to_line(offset.min(self.len()))
    }

    pub fn offset_to_col(&self, offset: usize) -> usize {
        let offset = offset.min(self.len());
        offset - self.text.line_to_char(self.text.char_to_line(offset))
    }

    /// Offset of (`line`, `col`), clamped so it never passes the end of the
    /// line's text.
    pub fn line_col_to_offset(&self, line: usize, col: usize) -> usize {
        let line = line.min(self.line_count().saturating_sub(1));
        self.text.line_to_char(line) + col.min(self.line_len(line))
    }

    /// Byte offset of char offset `offset` in [`Self::text`].
    pub fn char_to_byte(&self, offset: usize) -> usize {
        self.text.char_to_byte(offset.min(self.len()))
    }

    pub fn byte_to_char(&self, byte: usize) -> usize {
        self.text.byte_to_char(byte.min(self.text.len_bytes()))
    }

    /// Starts (or stops) recording edits for `take_edits`.
    pub fn track_edits(&mut self, on: bool) {
        self.edits = on.then(Vec::new);
    }

    /// The edits since the last call, oldest first.
    pub fn take_edits(&mut self) -> Vec<Edit> {
        self.edits.as_mut().map(std::mem::take).unwrap_or_default()
    }

    /// The (row, byte column) of byte offset `byte`.
    fn point(&self, byte: usize) -> (usize, usize) {
        let row = self.text.byte_to_line(byte);
        (row, byte - self.text.line_to_byte(row))
    }

    fn record(&mut self, edit: Edit) {
        if let Some(edits) = self.edits.as_mut() {
            edits.push(edit);
        }
    }

    fn record_reset(&mut self) {
        if let Some(edits) = self.edits.as_mut() {
            edits.clear();
            edits.push(Edit::Reset);
        }
    }

    pub fn insert(&mut self, offset: usize, text: &str) {
        if text.is_empty() {
            return;
        }
        let offset = offset.min(self.len());
        let tracking = self.edits.is_some();
        let before = tracking.then(|| {
            let b = self.text.char_to_byte(offset);
            (b, self.point(b))
        });
        self.text.insert(offset, text);
        if let Some((start_byte, start)) = before {
            let new_end_byte = start_byte + text.len();
            let new_end = self.point(new_end_byte);
            self.record(Edit::Change {
                start_byte,
                old_end_byte: start_byte,
                new_end_byte,
                start,
                old_end: start,
                new_end,
            });
        }
        self.version += 1;
        let n = text.chars().count();
        for m in self.marks.values_mut() {
            if *m >= offset {
                *m += n;
            }
        }
        self.modified = true;
        self.dirty = true;
        self.redo.clear();
    }

    /// Deletes the chars in `start..end`, clamped to the buffer, and returns
    /// them.
    pub fn delete(&mut self, start: usize, end: usize) -> String {
        let end = end.min(self.len());
        let start = start.min(end);
        let removed = self.text.slice(start..end).to_string();
        let before = (self.edits.is_some() && start < end).then(|| {
            let (sb, eb) = (self.text.char_to_byte(start), self.text.char_to_byte(end));
            (sb, eb, self.point(sb), self.point(eb))
        });
        self.text.remove(start..end);
        if let Some((start_byte, old_end_byte, start_point, old_end)) = before {
            self.record(Edit::Change {
                start_byte,
                old_end_byte,
                new_end_byte: start_byte,
                start: start_point,
                old_end,
                new_end: start_point,
            });
        }
        if start < end {
            self.version += 1;
        }
        for m in self.marks.values_mut() {
            if *m >= end {
                *m -= end - start;
            } else if *m > start {
                *m = start;
            }
        }
        if !removed.is_empty() {
            self.modified = true;
            self.dirty = true;
            self.redo.clear();
        }
        removed
    }

    pub fn set_mark(&mut self, name: &str, offset: usize) {
        self.marks.insert(name.to_string(), offset.min(self.len()));
    }

    /// Where mark `name` is, kept inside the text (undo can shrink it).
    pub fn mark(&self, name: &str) -> Option<usize> {
        self.marks.get(name).map(|&m| m.min(self.len()))
    }

    pub fn delete_mark(&mut self, name: &str) {
        self.marks.remove(name);
    }

    pub fn mark_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.marks.keys().cloned().collect();
        names.sort();
        names
    }

    /// Records the current text as an undo point. The editing layer calls
    /// this once per change it wants undone as a unit.
    pub fn undo_boundary(&mut self) {
        if self.dirty || self.undo.is_empty() {
            self.undo.push(self.text.clone());
            self.dirty = false;
        }
    }

    /// Goes back to the last undo point. Returns where the text changed
    /// (the first char that differs), or `None` when there is nothing to
    /// undo.
    pub fn undo(&mut self) -> Option<usize> {
        // Changes since the last boundary are undone first, so they can be
        // redone too.
        if self.dirty {
            self.undo_boundary();
        }
        let mut previous = self.undo.pop()?;
        // The top snapshot can equal the text (a boundary with no change
        // after it); skip it to undo something visible.
        if previous == self.text {
            previous = match self.undo.pop() {
                Some(p) => p,
                None => {
                    self.undo.push(previous);
                    return None;
                }
            };
        }
        let at = first_difference(&previous, &self.text);
        self.version += 1;
        self.record_reset();
        self.redo.push(std::mem::replace(&mut self.text, previous));
        self.modified = true;
        self.dirty = false;
        Some(at)
    }

    pub fn redo(&mut self) -> Option<usize> {
        let next = self.redo.pop()?;
        let at = first_difference(&next, &self.text);
        self.version += 1;
        self.record_reset();
        self.undo.push(std::mem::replace(&mut self.text, next));
        self.modified = true;
        self.dirty = false;
        Some(at)
    }
}

/// The text of `path` and its format; a missing file is empty.
fn read_file(path: &Path) -> io::Result<(String, FileFormat)> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(fileio::decode(&bytes)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok((String::new(), FileFormat::default())),
        Err(e) => Err(e),
    }
}

/// The char offset of the first difference between two texts.
fn first_difference(a: &Rope, b: &Rope) -> usize {
    a.chars()
        .zip(b.chars())
        .position(|(x, y)| x != y)
        .unwrap_or(a.len_chars().min(b.len_chars()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_ignore_trailing_newline() {
        let b = Buffer::from_text("one\ntwo\n");
        assert_eq!(b.line_count(), 2);
        assert_eq!(b.line_len(0), 3);
        assert_eq!(b.line_text(1), "two");
        assert_eq!(Buffer::from_text("").line_count(), 1);
    }

    #[test]
    fn offsets_round_trip() {
        let b = Buffer::from_text("ab\ncde\n");
        assert_eq!(b.line_col_to_offset(1, 2), 5);
        assert_eq!(b.offset_to_line(5), 1);
        assert_eq!(b.offset_to_col(5), 2);
        // Columns clamp to the end of the line's text.
        assert_eq!(b.line_col_to_offset(0, 99), 2);
    }

    #[test]
    fn edits_are_recorded_for_parsers() {
        let mut b = Buffer::from_text("ab\ncd\n");
        b.insert(0, "x");
        assert!(b.take_edits().is_empty());
        b.track_edits(true);
        b.insert(4, "é");
        b.delete(0, 2);
        let edits = b.take_edits();
        assert_eq!(
            edits[0],
            Edit::Change {
                start_byte: 4,
                old_end_byte: 4,
                new_end_byte: 6,
                start: (1, 0),
                old_end: (1, 0),
                new_end: (1, 2),
            }
        );
        assert_eq!(
            edits[1],
            Edit::Change {
                start_byte: 0,
                old_end_byte: 2,
                new_end_byte: 0,
                start: (0, 0),
                old_end: (0, 2),
                new_end: (0, 0),
            }
        );
        b.undo_boundary();
        b.insert(0, "z");
        b.undo();
        assert_eq!(b.take_edits(), [Edit::Reset]);
        assert!(b.take_edits().is_empty());
    }

    #[test]
    fn marks_follow_edits() {
        let mut b = Buffer::from_text("abcdef");
        b.set_mark("a", 3);
        b.set_mark("b", 5);
        b.insert(1, "xx");
        assert_eq!(b.mark("a"), Some(5));
        b.delete(4, 6);
        assert_eq!(b.mark("a"), Some(4));
        assert_eq!(b.mark("b"), Some(5));
        b.delete(0, 8);
        assert_eq!(b.mark("b"), Some(0));
    }

    #[test]
    fn undo_restores_snapshot() {
        let mut b = Buffer::from_text("hello");
        b.undo_boundary();
        b.delete(0, 2);
        assert_eq!(b.text(), "llo");
        assert_eq!(b.undo(), Some(0));
        assert_eq!(b.text(), "hello");
        assert_eq!(b.redo(), Some(0));
        assert_eq!(b.text(), "llo");
        assert_eq!(b.undo(), Some(0));
        assert_eq!(b.undo(), None);
    }

    #[test]
    fn boundaries_without_changes_add_nothing() {
        let mut b = Buffer::from_text("abc");
        b.undo_boundary();
        b.undo_boundary();
        b.insert(3, "d");
        b.undo_boundary();
        b.undo_boundary();
        b.insert(4, "e");
        assert_eq!(b.undo(), Some(4));
        assert_eq!(b.text(), "abcd");
        assert_eq!(b.undo(), Some(3));
        assert_eq!(b.text(), "abc");
        assert_eq!(b.undo(), None);
    }
}
