//! Editor state, owned by the thread that owns the Steel VM.
//!
//! Steel's functions are plain Rust functions, so the state they act on lives
//! in a thread-local. Only the server's main loop touches it; other work
//! (LSP, file watching) will post messages to that loop instead.

use std::cell::RefCell;
use std::collections::HashMap;

use imp_core::{Buffer, CursorShape, Style};
use regex::Regex;

#[derive(Debug, Default)]
pub struct Editor {
    pub buffer: Buffer,
    /// Cursor as a char offset into the buffer.
    pub cursor: usize,
    pub mode_name: String,
    pub cursor_shape: CursorShape,
    pub status: String,
    pub quit: bool,
    /// First buffer line shown on screen.
    pub scroll: usize,
    pub width: u16,
    pub height: u16,
    /// Named styles. Highlights refer to faces by name, so redefining a face
    /// restyles everything that uses it.
    pub faces: HashMap<String, Style>,
    /// Highlight layers in drawing order: later layers draw over earlier ones.
    pub layers: Vec<Layer>,
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
