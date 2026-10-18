//! A text buffer: a rope plus a file path and snapshot-based undo.
//!
//! Positions are char offsets into the whole text. Line/column conversions are
//! provided for the editing layer, which decides what the positions mean.

use std::io;
use std::path::{Path, PathBuf};

use ropey::Rope;

#[derive(Debug, Default)]
pub struct Buffer {
    text: Rope,
    path: Option<PathBuf>,
    modified: bool,
    // Rope clones share structure, so a snapshot is cheap.
    undo: Vec<Rope>,
    redo: Vec<Rope>,
}

impl Buffer {
    pub fn from_text(text: &str) -> Self {
        Self {
            text: Rope::from_str(text),
            ..Self::default()
        }
    }

    /// Opens `path`, or starts an empty buffer for it if the file doesn't exist.
    pub fn open(path: &Path) -> io::Result<Self> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => Rope::from_str(&text),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Rope::new(),
            Err(e) => return Err(e),
        };
        Ok(Self {
            text,
            path: Some(path.to_path_buf()),
            ..Self::default()
        })
    }

    pub fn save(&mut self) -> io::Result<()> {
        let path = self
            .path
            .as_ref()
            .ok_or_else(|| io::Error::other("buffer has no file name"))?;
        let file = std::fs::File::create(path)?;
        self.text.write_to(io::BufWriter::new(file))?;
        self.modified = false;
        Ok(())
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
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

    pub fn insert(&mut self, offset: usize, text: &str) {
        self.text.insert(offset.min(self.len()), text);
        self.modified = true;
        self.redo.clear();
    }

    /// Deletes the chars in `start..end`, clamped to the buffer, and returns
    /// them.
    pub fn delete(&mut self, start: usize, end: usize) -> String {
        let end = end.min(self.len());
        let start = start.min(end);
        let removed = self.text.slice(start..end).to_string();
        self.text.remove(start..end);
        if !removed.is_empty() {
            self.modified = true;
            self.redo.clear();
        }
        removed
    }

    /// Records the current text as an undo point. The editing layer calls
    /// this once per change it wants undone as a unit.
    pub fn undo_boundary(&mut self) {
        if self.undo.last() != Some(&self.text) {
            self.undo.push(self.text.clone());
        }
    }

    /// Returns false when there is nothing to undo.
    pub fn undo(&mut self) -> bool {
        let Some(previous) = self.undo.pop() else {
            return false;
        };
        self.redo.push(std::mem::replace(&mut self.text, previous));
        self.modified = true;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(next) = self.redo.pop() else {
            return false;
        };
        self.undo.push(std::mem::replace(&mut self.text, next));
        self.modified = true;
        true
    }
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
    fn undo_restores_snapshot() {
        let mut b = Buffer::from_text("hello");
        b.undo_boundary();
        b.delete(0, 2);
        assert_eq!(b.text(), "llo");
        assert!(b.undo());
        assert_eq!(b.text(), "hello");
        assert!(b.redo());
        assert_eq!(b.text(), "llo");
    }
}
