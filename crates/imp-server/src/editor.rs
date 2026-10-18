//! Editor state, owned by the thread that owns the Steel VM.
//!
//! Steel's functions are plain Rust functions, so the state they act on lives
//! in a thread-local. Only the server's main loop touches it; other work
//! (LSP, file watching) will post messages to that loop instead.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use imp_core::{Buffer, CursorShape, Style};
use regex::Regex;

#[derive(Debug, Default)]
pub struct Editor {
    /// The current buffer. Every buffer primitive acts on this one; other
    /// buffers wait in `parked` until switched to.
    pub buffer: Buffer,
    /// Id of the current buffer.
    pub current: usize,
    pub parked: BTreeMap<usize, Parked>,
    pub next_id: usize,
    /// Cursor as a char offset into the buffer.
    pub cursor: usize,
    pub mode_name: String,
    /// Shown at the right of the status line, before the position (the
    /// buffer's major mode).
    pub mode_line_extra: String,
    pub cursor_shape: CursorShape,
    pub status: String,
    /// The command line being typed and the cursor's column in it. While
    /// it is set it replaces the status line, as in Vim.
    pub cmdline: Option<(String, usize)>,
    /// Scheme sources loaded so far: (name, path on disk if any, text), for
    /// documentation and jumping to definitions.
    pub sources: Vec<(String, Option<String>, String)>,
    /// Lines drawn over the bottom of the window, above the status line.
    pub popup: Vec<String>,
    /// The popup line drawn as selected, for completion menus.
    pub popup_selected: Option<usize>,
    pub quit: bool,
    /// First buffer line shown on screen.
    pub scroll: usize,
    /// First display column shown on screen (lines don't wrap).
    pub hscroll: usize,
    pub line_numbers: crate::render::LineNumbers,
    /// Whether the cursor's line is drawn with the "cursorline" face.
    pub cursorline: bool,
    pub width: u16,
    pub height: u16,
    /// Display columns between tab stops.
    pub tab_width: usize,
    /// Named styles. Highlights refer to faces by name, so redefining a face
    /// restyles everything that uses it.
    pub faces: HashMap<String, Style>,
    /// Highlight layers in drawing order: later layers draw over earlier ones.
    pub layers: Vec<Layer>,
}

/// A buffer that isn't current, with where its cursor and window were.
#[derive(Debug)]
pub struct Parked {
    pub buffer: Buffer,
    pub cursor: usize,
    pub scroll: usize,
}

/// A named set of highlighted ranges, such as the visual selection or the
/// search matches. Scheme replaces a layer's ranges as a whole.
#[derive(Debug, Default)]
pub struct Layer {
    pub name: String,
    pub ranges: Vec<Highlight>,
    /// Every match of this pattern is drawn with the face. Matches are found
    /// when drawing, on visible lines only, so they follow edits for free.
    pub pattern: Option<(Regex, String)>,
}

/// Chars `start..end` drawn with face `face`.
#[derive(Debug, Clone)]
pub struct Highlight {
    pub start: usize,
    pub end: usize,
    pub face: String,
}

impl Editor {
    /// Ids of all buffers, in the order they were made.
    pub fn buffer_ids(&self) -> Vec<usize> {
        let mut ids: Vec<usize> = self.parked.keys().copied().collect();
        ids.push(self.current);
        ids.sort_unstable();
        ids
    }

    pub fn buffer_by_id(&self, id: usize) -> Option<&Buffer> {
        if id == self.current {
            Some(&self.buffer)
        } else {
            self.parked.get(&id).map(|p| &p.buffer)
        }
    }

    /// Makes buffer `id` current. Returns false if there is no such buffer.
    pub fn switch_to(&mut self, id: usize) -> bool {
        if id == self.current {
            return true;
        }
        let Some(next) = self.parked.remove(&id) else {
            return false;
        };
        let old = Parked {
            buffer: std::mem::replace(&mut self.buffer, next.buffer),
            cursor: self.cursor,
            scroll: self.scroll,
        };
        self.hscroll = 0;
        self.parked.insert(self.current, old);
        self.current = id;
        self.cursor = next.cursor.min(self.buffer.len());
        self.scroll = next.scroll;
        true
    }

    /// Adds a buffer (not made current) and returns its id.
    pub fn add_buffer(&mut self, buffer: Buffer) -> usize {
        self.next_id += 1;
        let id = self.next_id;
        self.parked.insert(
            id,
            Parked {
                buffer,
                cursor: 0,
                scroll: 0,
            },
        );
        id
    }

    /// The buffer visiting `path`, if one is open.
    pub fn find_file_buffer(&self, path: &Path) -> Option<usize> {
        let wanted = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        self.buffer_ids().into_iter().find(|&id| {
            self.buffer_by_id(id)
                .and_then(|b| b.path())
                .is_some_and(|p| {
                    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf()) == wanted
                })
        })
    }

    /// Removes buffer `id`. Removing the current buffer switches to
    /// another one, or to a new empty buffer if it was the last.
    pub fn kill_buffer(&mut self, id: usize) -> bool {
        if id != self.current {
            return self.parked.remove(&id).is_some();
        }
        let next = match self.parked.keys().next() {
            Some(&next) => next,
            None => self.add_buffer(Buffer::default()),
        };
        self.switch_to(next);
        self.parked.remove(&id);
        true
    }
    /// Rows available for buffer text: everything but the status line.
    pub fn text_rows(&self) -> usize {
        self.height.saturating_sub(1).max(1) as usize
    }

    pub fn face(&self, name: &str) -> Style {
        self.faces.get(name).copied().unwrap_or_default()
    }

    /// The layer called `name`, created on top of the others if new.
    pub fn layer_mut(&mut self, name: &str) -> &mut Layer {
        let i = match self.layers.iter().position(|l| l.name == name) {
            Some(i) => i,
            None => {
                self.layers.push(Layer {
                    name: name.to_string(),
                    ..Layer::default()
                });
                self.layers.len() - 1
            }
        };
        &mut self.layers[i]
    }
}

thread_local! {
    static EDITOR: RefCell<Option<Editor>> = const { RefCell::new(None) };
}

/// Installs `editor` as this thread's editor, replacing any previous one.
pub fn install(editor: Editor) {
    EDITOR.with(|e| *e.borrow_mut() = Some(editor));
}

/// Runs `f` against this thread's editor.
///
/// Panics if no editor is installed, which would be a bug in the server: the
/// Scheme API is only reachable after `install`.
pub fn with<R>(f: impl FnOnce(&mut Editor) -> R) -> R {
    EDITOR.with(|e| {
        let mut e = e.borrow_mut();
        f(e.as_mut().expect("no editor installed on this thread"))
    })
}
