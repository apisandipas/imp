//! A text buffer: a rope plus a file path and snapshot-based undo.
//!
//! Positions are char offsets into the whole text. Line/column conversions are
//! provided for the editing layer, which decides what the positions mean.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ropey::Rope;

use crate::fileio::{self, FileFormat};

#[derive(Debug, Default)]
pub struct Buffer {
    text: Rope,
    path: Option<PathBuf>,
    /// Name of a buffer with no file, such as "*messages*".
    name: Option<String>,
    modified: bool,
    /// The undo tree: every state the text was in at an undo point, each
    /// a child of the one it was made from. Rope clones share structure,
    /// so a snapshot is cheap.
    states: Vec<UndoState>,
    /// The state the text is in, or was in before changes since (`dirty`).
    state: usize,
    /// Whether the text changed since the last undo point, so a boundary
    /// knows whether to record one without comparing ropes.
    dirty: bool,
    /// Named positions that move with the text around them. Vim's marks,
    /// the jump list and anything else Scheme wants kept in place.
    marks: HashMap<String, usize>,
    /// Marks that stay put when text is inserted right where they are,
    /// instead of moving after it.
    sticky: HashSet<String>,
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
    /// Vim's 'nomodifiable': the server refuses to change the text (the
    /// buffer itself doesn't check).
    pub read_only: bool,
    /// Edits since a parser last looked, when something asked to track
    /// them (a syntax tree; see `track_edits`).
    edits: Option<Vec<Edit>>,
    /// The text as one string and the version it was copied at, for
    /// `shared_text`. Kept until the next search after a change, so a
    /// searched buffer holds a second copy of its text.
    shared: RefCell<Option<(u64, Arc<str>)>>,
    /// The last `CHANGE_LOG` edits, each with the version it made, for
    /// `changes_since`; any number of readers can each keep a version.
    changes: VecDeque<(u64, Change)>,
    /// The oldest version `changes_since` can start from: edits before it
    /// were dropped, or an undo, redo or reload replaced the whole text.
    changes_from: u64,
}

/// One state in the undo tree: the text and marks at an undo point. Its
/// index in `Buffer::states` is its change number, in the order made.
#[derive(Debug)]
struct UndoState {
    text: Rope,
    marks: HashMap<String, usize>,
    parent: Option<usize>,
    /// The child last visited: where redo goes.
    last_child: Option<usize>,
    made: std::time::SystemTime,
}

/// How many edits `changes_since` can reach back.
const CHANGE_LOG: usize = 1000;

/// One edit, in chars: `start..old_end` became `start..new_end`, holding
/// `text`. The (line, column) points are where it started and ended
/// before it was made, as an LSP range wants them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    pub start: usize,
    pub old_end: usize,
    pub new_end: usize,
    pub text: String,
    pub start_point: (usize, usize),
    pub old_end_point: (usize, usize),
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

    /// The text as one string, for searching it with a regex. It is copied
    /// once per version and shared until the text changes, so repeated
    /// searches (`n`, each key of an incremental search) don't copy it.
    pub fn shared_text(&self) -> Arc<str> {
        let mut shared = self.shared.borrow_mut();
        match &*shared {
            Some((version, text)) if *version == self.version => text.clone(),
            _ => {
                let text: Arc<str> = self.text.to_string().into();
                *shared = Some((self.version, text.clone()));
                text
            }
        }
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
        self.changes.clear();
        self.changes_from = self.version;
    }

    /// The (line, column) of char offset `offset`.
    fn char_point(&self, offset: usize) -> (usize, usize) {
        let line = self.text.char_to_line(offset);
        (line, offset - self.text.line_to_char(line))
    }

    /// Logs `change`, made by the version just reached.
    fn log_change(&mut self, change: Change) {
        self.changes.push_back((self.version, change));
        if self.changes.len() > CHANGE_LOG {
            if let Some((version, _)) = self.changes.pop_front() {
                self.changes_from = version;
            }
        }
    }

    /// The edits made since the text was at `version`, oldest first, or
    /// `None` when they aren't known: across an undo, redo or reload, or
    /// more than `CHANGE_LOG` edits back.
    pub fn changes_since(&self, version: u64) -> Option<Vec<Change>> {
        if version < self.changes_from || version > self.version {
            return None;
        }
        Some(
            self.changes
                .iter()
                .filter(|(v, _)| *v > version)
                .map(|(_, c)| c.clone())
                .collect(),
        )
    }

    pub fn insert(&mut self, offset: usize, text: &str) {
        if text.is_empty() {
            return;
        }
        let offset = offset.min(self.len());
        let start_point = self.char_point(offset);
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
        self.log_change(Change {
            start: offset,
            old_end: offset,
            new_end: offset + n,
            text: text.to_string(),
            start_point,
            old_end_point: start_point,
        });
        for (name, m) in self.marks.iter_mut() {
            if *m > offset || (*m == offset && !self.sticky.contains(name)) {
                *m += n;
            }
        }
        self.modified = true;
        self.dirty = true;
    }

    /// Deletes the chars in `start..end`, clamped to the buffer, and returns
    /// them.
    pub fn delete(&mut self, start: usize, end: usize) -> String {
        let end = end.min(self.len());
        let start = start.min(end);
        let removed = self.text.slice(start..end).to_string();
        let points = (start < end).then(|| (self.char_point(start), self.char_point(end)));
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
        if let Some((start_point, old_end_point)) = points {
            self.version += 1;
            self.log_change(Change {
                start,
                old_end: end,
                new_end: start,
                text: String::new(),
                start_point,
                old_end_point,
            });
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
        }
        removed
    }

    pub fn set_mark(&mut self, name: &str, offset: usize) {
        self.marks.insert(name.to_string(), offset.min(self.len()));
        self.sticky.remove(name);
    }

    /// Sets a mark that text inserted at it goes after, as at the start of
    /// a line whose name is being retyped.
    pub fn set_sticky_mark(&mut self, name: &str, offset: usize) {
        self.set_mark(name, offset);
        self.sticky.insert(name.to_string());
    }

    /// Where mark `name` is, kept inside the text (undo can shrink it).
    pub fn mark(&self, name: &str) -> Option<usize> {
        self.marks.get(name).map(|&m| m.min(self.len()))
    }

    pub fn delete_mark(&mut self, name: &str) {
        self.marks.remove(name);
        self.sticky.remove(name);
    }

    pub fn mark_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.marks.keys().cloned().collect();
        names.sort();
        names
    }

    /// Records the current text as an undo point: a new state in the undo
    /// tree, the child of the current one, if the text changed since. The
    /// editing layer calls this once per change it wants undone as a unit.
    pub fn undo_boundary(&mut self) {
        if self.states.is_empty() || self.dirty {
            let parent = (!self.states.is_empty()).then_some(self.state);
            let id = self.states.len();
            self.states.push(UndoState {
                text: self.text.clone(),
                marks: self.marks.clone(),
                parent,
                last_child: None,
                made: std::time::SystemTime::now(),
            });
            if let Some(p) = parent {
                self.states[p].last_child = Some(id);
            }
            self.state = id;
            self.dirty = false;
        }
    }

    /// Goes back to the state before the current one. Returns where the
    /// text changed (the first char that differs), or `None` when there is
    /// nothing to undo.
    pub fn undo(&mut self) -> Option<usize> {
        // Changes since the last boundary are undone first, so they can be
        // redone too.
        self.undo_boundary();
        let parent = self.states[self.state].parent?;
        self.states[parent].last_child = Some(self.state);
        Some(self.go_to_state(parent))
    }

    /// Goes forward to the state last undone from, along the branch last
    /// taken. `None` when there is none.
    pub fn redo(&mut self) -> Option<usize> {
        self.undo_boundary();
        let child = self.states[self.state].last_child?;
        Some(self.go_to_state(child))
    }

    /// Goes to the state made just after (`forward`) or before the current
    /// one, whatever branch it is on, as Vim's g+ and g- do. `None` past
    /// the newest or the oldest.
    pub fn undo_step(&mut self, forward: bool) -> Option<usize> {
        self.undo_boundary();
        let target = if forward {
            Some(self.state + 1).filter(|&s| s < self.states.len())?
        } else {
            self.state.checked_sub(1)?
        };
        // Undo and redo from there follow the path that leads to it.
        let mut node = target;
        while let Some(parent) = self.states[node].parent {
            self.states[parent].last_child = Some(node);
            node = parent;
        }
        Some(self.go_to_state(target))
    }

    /// The tip of each branch of the undo tree, oldest first, as (change
    /// number, changes deep, when it was made). Changes since the last
    /// undo point become a state first, as undo would make them.
    pub fn undo_list(&mut self) -> Vec<(usize, usize, std::time::SystemTime)> {
        self.undo_boundary();
        let parents: HashSet<usize> = self.states.iter().filter_map(|s| s.parent).collect();
        (1..self.states.len())
            .filter(|i| !parents.contains(i))
            .map(|i| {
                let mut depth = 0;
                let mut node = i;
                while let Some(p) = self.states[node].parent {
                    depth += 1;
                    node = p;
                }
                (i, depth, self.states[i].made)
            })
            .collect()
    }

    /// Puts the text and marks back as they were in state `id`. Marks the
    /// state doesn't know keep their place, clamped into the text. Returns
    /// the first char that differs.
    fn go_to_state(&mut self, id: usize) -> usize {
        let at = first_difference(&self.states[id].text, &self.text);
        self.text = self.states[id].text.clone();
        for (name, &offset) in &self.states[id].marks {
            self.marks.insert(name.clone(), offset);
        }
        let len = self.len();
        for m in self.marks.values_mut() {
            *m = (*m).min(len);
        }
        self.state = id;
        self.version += 1;
        self.record_reset();
        self.modified = true;
        self.dirty = false;
        at
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
    fn shared_text_is_copied_once_per_change() {
        let mut b = Buffer::from_text("one\n");
        let first = b.shared_text();
        assert!(Arc::ptr_eq(&first, &b.shared_text()));
        b.undo_boundary();
        b.insert(0, "zero ");
        assert_eq!(&*b.shared_text(), "zero one\n");
        b.undo();
        assert_eq!(&*b.shared_text(), "one\n");
    }

    /// Makes one undoable change: a boundary, then `text` at the end.
    fn change(b: &mut Buffer, text: &str) {
        b.undo_boundary();
        b.insert(b.len(), text);
    }

    #[test]
    fn a_change_after_undo_starts_a_branch() {
        let mut b = Buffer::from_text("");
        change(&mut b, "a");
        change(&mut b, "b");
        b.undo();
        assert_eq!(b.text(), "a");
        change(&mut b, "c");
        assert_eq!(b.text(), "ac");
        // u and C-r follow the new branch.
        b.undo();
        assert_eq!(b.text(), "a");
        b.redo();
        assert_eq!(b.text(), "ac");
        assert_eq!(b.redo(), None);
        // g- and g+ step through the states in the order they were made,
        // across branches: "", "a", "ab", "ac".
        b.undo_step(false);
        assert_eq!(b.text(), "ab");
        b.undo_step(false);
        assert_eq!(b.text(), "a");
        b.undo_step(false);
        assert_eq!(b.text(), "");
        assert_eq!(b.undo_step(false), None);
        b.undo_step(true);
        b.undo_step(true);
        assert_eq!(b.text(), "ab");
        // From there C-r and u follow the path to it.
        b.undo();
        assert_eq!(b.text(), "a");
        b.redo();
        assert_eq!(b.text(), "ab");
        // The tips of the two branches, two changes deep each.
        let tips: Vec<(usize, usize)> = b.undo_list().iter().map(|&(n, d, _)| (n, d)).collect();
        assert_eq!(tips, vec![(2, 2), (3, 2)]);
    }

    #[test]
    fn undo_puts_marks_back() {
        let mut b = Buffer::from_text("one two\n");
        b.set_mark("a", 4);
        b.undo_boundary();
        b.delete(0, 4);
        assert_eq!(b.mark("a"), Some(0));
        b.set_mark("new", 3);
        b.undo();
        assert_eq!(b.text(), "one two\n");
        assert_eq!(b.mark("a"), Some(4));
        // A mark set since keeps its place.
        assert_eq!(b.mark("new"), Some(3));
        b.redo();
        assert_eq!(b.mark("a"), Some(0));
    }

    #[test]
    fn changes_since_a_version() {
        let mut b = Buffer::from_text("one\ntwo\n");
        let v = b.version();
        b.insert(4, "2");
        b.delete(0, 2);
        let changes = b.changes_since(v).unwrap();
        assert_eq!(
            changes,
            vec![
                Change {
                    start: 4,
                    old_end: 4,
                    new_end: 5,
                    text: "2".into(),
                    start_point: (1, 0),
                    old_end_point: (1, 0),
                },
                Change {
                    start: 0,
                    old_end: 2,
                    new_end: 0,
                    text: String::new(),
                    start_point: (0, 0),
                    old_end_point: (0, 2),
                },
            ]
        );
        // Each reader keeps its own version.
        assert_eq!(b.changes_since(v + 1).unwrap().len(), 1);
        assert_eq!(b.changes_since(b.version()).unwrap(), vec![]);
        // Nothing deleted is no change.
        b.delete(1, 1);
        assert_eq!(b.changes_since(v).unwrap().len(), 2);
    }

    #[test]
    fn changes_are_unknown_across_undo_and_far_back() {
        let mut b = Buffer::from_text("x");
        let v = b.version();
        b.undo_boundary();
        b.insert(0, "a");
        b.undo();
        assert_eq!(b.changes_since(v), None);
        let after = b.version();
        b.insert(0, "b");
        assert_eq!(b.changes_since(after).unwrap().len(), 1);
        for _ in 0..CHANGE_LOG {
            b.insert(0, "c");
        }
        assert_eq!(b.changes_since(after), None);
        assert_eq!(b.changes_since(after + 1).unwrap().len(), CHANGE_LOG);
    }

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
    fn sticky_marks_stay_before_text_inserted_at_them() {
        let mut b = Buffer::from_text("ab");
        b.set_sticky_mark("s", 1);
        b.set_mark("m", 1);
        b.insert(1, "xx");
        assert_eq!(b.mark("s"), Some(1));
        assert_eq!(b.mark("m"), Some(3));
        b.insert(0, "y");
        assert_eq!(b.mark("s"), Some(2));
        // Setting it again plainly makes it an ordinary mark.
        b.set_mark("s", 0);
        b.insert(0, "z");
        assert_eq!(b.mark("s"), Some(1));
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
