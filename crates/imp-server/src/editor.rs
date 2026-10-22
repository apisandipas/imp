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

use crate::layout::{Dir, Layout, Rect};

/// One line's margin text: (text, face) parts.
pub type MarginText = Vec<(String, String)>;

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
    /// Lines drawn over the windows: at the bottom of the screen, or in a
    /// box at the cursor (see `popup_at_cursor`).
    pub popup: Vec<PopupLine>,
    /// The popup line drawn as selected, for completion menus.
    pub popup_selected: Option<usize>,
    /// None puts the popup at the bottom; Some(dx) in a bordered box under
    /// (or over) the cursor, shifted `dx` columns.
    pub popup_at_cursor: Option<isize>,
    /// Whether the box at the cursor went under it (Some(true)) or over
    /// it, kept until the popup closes so it doesn't flip sides as it
    /// shrinks.
    pub popup_under: std::cell::Cell<Option<bool>>,
    /// Some(percent) puts the popup in a box in the middle of the screen,
    /// that percent of its width, with the command line's text in the box
    /// instead of at the bottom (the posframe package).
    pub popup_center: Option<usize>,
    /// Shown in the popup's top border; empty for none.
    pub popup_title: String,
    /// The status line formats (see render::status_line), for the focused
    /// window and the others.
    pub statusline: String,
    pub statusline_inactive: String,
    /// The face `%#mode#` uses in the status line, set with the mode.
    pub mode_face: String,
    /// Values for `%{name}` in the status line: per buffer, and global
    /// ones under `usize::MAX`.
    pub status_values: HashMap<usize, HashMap<String, String>>,
    pub quit: bool,
    /// Set by :kill-server: a daemon stops instead of detaching a client.
    pub kill_server: bool,
    /// First buffer line shown in the current window.
    pub scroll: usize,
    /// First display column shown in the current window (without wrap).
    pub hscroll: usize,
    /// Every window. The current window's scroll and cursor live in the
    /// fields above while it is current; another window's cursor is a
    /// mark in its buffer (see `window_mark`), so edits keep it in place.
    pub windows: BTreeMap<usize, Window>,
    pub layout: Layout,
    pub current_window: usize,
    pub next_window_id: usize,
    /// Whether long lines wrap onto the next screen rows.
    pub wrap: bool,
    /// With wrap, rows end between words rather than inside one (Vim's
    /// 'linebreak').
    pub linebreak: bool,
    pub line_numbers: crate::render::LineNumbers,
    /// Whether the cursor's line is drawn with the "cursorline" face.
    pub cursorline: bool,
    pub width: u16,
    pub height: u16,
    /// Display columns between tab stops.
    pub tab_width: usize,
    /// Parse trees, by buffer id, for buffers with a language.
    pub syntax: HashMap<usize, crate::syntax::Syntax>,
    /// Gutter signs by buffer id: line -> (text, face). A buffer with any
    /// gets a two-cell column before its line numbers (diagnostics,
    /// breakpoints).
    pub signs: HashMap<usize, BTreeMap<usize, (String, String)>>,
    /// When each buffer shows its sign column (the `signcolumn` option);
    /// a buffer not here shows it only while it has signs.
    pub sign_columns: HashMap<usize, crate::render::SignColumn>,
    /// Display-only text before lines, by buffer id: line -> (text,
    /// face) parts. It takes a column as wide as the widest, after the
    /// line numbers, and can't be edited (the file browser's details).
    pub margins: HashMap<usize, BTreeMap<usize, MarginText>>,
    /// The width the text of a buffer takes, centred in its windows with
    /// blank margins either side (olivetti), by buffer id. Unset, text
    /// fills the window.
    pub body_widths: HashMap<usize, usize>,
    /// Each buffer's closed folds as (first, last) lines: sorted, not
    /// nested. Scheme decides where folds are (runtime/fold.scm).
    pub folds: HashMap<usize, Vec<(usize, usize)>>,
    /// Timers and jobs, which report back through the server's events.
    pub background: crate::events::Background,
    /// Named styles. Highlights refer to faces by name, so redefining a face
    /// restyles everything that uses it.
    pub faces: HashMap<String, Style>,
    /// Highlight layers in drawing order: later layers draw over earlier ones.
    pub layers: Vec<Layer>,
    /// Each buffer's own highlight layers, drawn wherever it is shown.
    pub buffer_layers: HashMap<usize, Vec<Layer>>,
    /// Font, padding and opacity for clients; frame() adds the background.
    pub appearance: imp_core::Appearance,
}

/// One popup row: runs of (text, face); an empty face means the popup's.
pub type PopupLine = Vec<(String, String)>;

/// A window: a view of a buffer.
#[derive(Debug, Clone)]
pub struct Window {
    pub buffer: usize,
    pub scroll: usize,
    pub hscroll: usize,
}

/// The buffer mark that holds window `id`'s cursor while it isn't current.
pub fn window_mark(id: usize) -> String {
    format!("window:{id}")
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
    /// What this pattern's groups match (all of a match without groups)
    /// is hidden, on every line but the cursor's. Buffer layers only.
    pub conceal: Option<Regex>,
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

    /// Buffer `id` and its cursor, to change a buffer that may not be
    /// current.
    pub fn buffer_and_cursor_mut(&mut self, id: usize) -> Option<(&mut Buffer, &mut usize)> {
        if id == self.current {
            Some((&mut self.buffer, &mut self.cursor))
        } else {
            self.parked
                .get_mut(&id)
                .map(|p| (&mut p.buffer, &mut p.cursor))
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
        if let Some(w) = self.windows.get_mut(&self.current_window) {
            w.buffer = id;
        }
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

    /// Removes buffer `id`. Windows showing it show another buffer; if it
    /// was the last buffer, a new empty one.
    pub fn kill_buffer(&mut self, id: usize) -> bool {
        if id != self.current && !self.parked.contains_key(&id) {
            return false;
        }
        let other = self
            .buffer_ids()
            .into_iter()
            .find(|&b| b != id)
            .unwrap_or_else(|| self.add_buffer(Buffer::default()));
        let showing: Vec<usize> = self
            .windows
            .iter()
            .filter(|(_, w)| w.buffer == id)
            .map(|(&wid, _)| wid)
            .collect();
        for wid in showing {
            if wid == self.current_window {
                self.switch_to(other);
            } else if let Some(w) = self.windows.get_mut(&wid) {
                *w = Window {
                    buffer: other,
                    scroll: 0,
                    hscroll: 0,
                };
            }
        }
        if id == self.current {
            self.switch_to(other);
        }
        self.parked.remove(&id);
        self.syntax.remove(&id);
        self.buffer_layers.remove(&id);
        self.folds.remove(&id);
        self.signs.remove(&id);
        self.sign_columns.remove(&id);
        self.margins.remove(&id);
        self.body_widths.remove(&id);
        self.status_values.remove(&id);
        true
    }

    /// Brings buffer `id`'s parse tree up to date, if it has one (see
    /// `Syntax::update` for the time budget).
    pub fn update_syntax(&mut self, id: usize) {
        if let Some(mut syntax) = self.syntax.remove(&id) {
            let events = self.background.sender.clone();
            if let Some(buffer) = self.buffer_by_id_mut(id) {
                syntax.update(buffer, id, events.as_ref());
            }
            self.syntax.insert(id, syntax);
        }
    }

    /// A background parse of buffer `id` finished.
    pub fn syntax_parsed(&mut self, id: usize, version: u64, tree: tree_sitter::Tree) {
        if let Some(mut syntax) = self.syntax.remove(&id) {
            if let Some(buffer) = self.buffer_by_id(id) {
                syntax.background_parsed(buffer, version, tree);
            }
            self.syntax.insert(id, syntax);
        }
    }

    /// The screen area windows share: all but the message line.
    pub fn windows_area(&self) -> Rect {
        Rect {
            x: 0,
            y: 0,
            w: self.width.max(1) as usize,
            h: self.height.saturating_sub(1).max(2) as usize,
        }
    }

    pub fn window_rect(&self, id: usize) -> Rect {
        self.layout
            .rects(self.windows_area())
            .into_iter()
            .find(|(w, _)| *w == id)
            .map(|(_, r)| r)
            .unwrap_or_else(|| self.windows_area())
    }

    /// Rows for text in the current window: its height less its status
    /// line.
    pub fn text_rows(&self) -> usize {
        self.window_rect(self.current_window)
            .h
            .saturating_sub(1)
            .max(1)
    }

    /// Makes the first window, showing the current buffer. Called once
    /// when the editor is set up.
    pub fn init_windows(&mut self) {
        self.next_window_id = 1;
        self.current_window = 1;
        self.windows.insert(
            1,
            Window {
                buffer: self.current,
                scroll: 0,
                hscroll: 0,
            },
        );
        self.layout = Layout::Window(1);
    }

    /// Makes window `id` current, bringing its buffer, cursor and scroll.
    pub fn focus_window(&mut self, id: usize) -> bool {
        if id == self.current_window {
            return true;
        }
        let Some(target) = self.windows.get(&id).cloned() else {
            return false;
        };
        let old = self.current_window;
        self.buffer.set_mark(&window_mark(old), self.cursor);
        if let Some(w) = self.windows.get_mut(&old) {
            w.scroll = self.scroll;
            w.hscroll = self.hscroll;
        }
        self.current_window = id;
        if target.buffer != self.current {
            self.switch_to(target.buffer);
        }
        self.cursor = self.buffer.mark(&window_mark(id)).unwrap_or(self.cursor);
        self.buffer.delete_mark(&window_mark(id));
        self.scroll = target.scroll;
        self.hscroll = target.hscroll;
        true
    }

    /// Splits the current window; the new window shows the same buffer at
    /// the same place and becomes current. `dir` and `before` place it.
    pub fn split_window(&mut self, dir: Dir, before: bool) -> usize {
        self.next_window_id += 1;
        let id = self.next_window_id;
        self.windows.insert(
            id,
            Window {
                buffer: self.current,
                scroll: self.scroll,
                hscroll: self.hscroll,
            },
        );
        self.layout.split(self.current_window, id, dir, before);
        self.buffer.set_mark(&window_mark(id), self.cursor);
        self.focus_window(id);
        id
    }

    /// Opens a window along an edge of the frame, `fraction` of its width
    /// or height, showing the current buffer and focused.
    pub fn split_frame(&mut self, dir: Dir, before: bool, fraction: f64) -> usize {
        self.next_window_id += 1;
        let id = self.next_window_id;
        self.windows.insert(
            id,
            Window {
                buffer: self.current,
                scroll: self.scroll,
                hscroll: self.hscroll,
            },
        );
        self.layout.split_edge(id, dir, before, fraction);
        self.buffer.set_mark(&window_mark(id), self.cursor);
        self.focus_window(id);
        id
    }

    /// Closes window `id`, focusing a neighbor if it was current. The last
    /// window can't be closed.
    pub fn close_window(&mut self, id: usize) -> bool {
        if self.windows.len() < 2 || !self.windows.contains_key(&id) {
            return false;
        }
        // The window that takes the space: the one before it, or after.
        let order = self.layout.windows();
        let i = order.iter().position(|&w| w == id).unwrap_or(0);
        let next = if i > 0 { order[i - 1] } else { order[1] };
        if id == self.current_window {
            self.focus_window(next);
        }
        let w = self.windows.remove(&id).expect("checked above");
        if let Some(b) = self.buffer_by_id_mut(w.buffer) {
            b.delete_mark(&window_mark(id));
        }
        self.layout.remove(id);
        true
    }

    pub fn only_window(&mut self) {
        let others: Vec<usize> = self
            .windows
            .keys()
            .copied()
            .filter(|&w| w != self.current_window)
            .collect();
        for w in others {
            self.close_window(w);
        }
    }

    pub fn buffer_by_id_mut(&mut self, id: usize) -> Option<&mut Buffer> {
        if id == self.current {
            Some(&mut self.buffer)
        } else {
            self.parked.get_mut(&id).map(|p| &mut p.buffer)
        }
    }

    /// The window beside the current one in direction (dx, dy), measured
    /// from the cursor's screen row or column as Vim does.
    pub fn window_in_direction(
        &self,
        dx: isize,
        dy: isize,
        cursor_screen: (usize, usize),
    ) -> Option<usize> {
        let rects = self.layout.rects(self.windows_area());
        let here = self.window_rect(self.current_window);
        let (cx, cy) = cursor_screen;
        let (x, y) = match (dx, dy) {
            (-1, _) => (here.x.checked_sub(2)?, cy),
            (1, _) => (here.x + here.w + 1, cy),
            (_, -1) => (cx, here.y.checked_sub(1)?),
            _ => (cx, here.y + here.h),
        };
        rects
            .iter()
            .find(|(_, r)| r.contains(x, y))
            .or_else(|| {
                // The cursor's row or column may miss a narrower window;
                // take the nearest along the edge.
                rects.iter().find(|(w, r)| {
                    *w != self.current_window
                        && match (dx, dy) {
                            (-1, _) => r.x + r.w + 1 == here.x,
                            (1, _) => r.x == here.x + here.w + 1,
                            (_, -1) => r.y + r.h == here.y,
                            _ => r.y == here.y + here.h,
                        }
                })
            })
            .map(|(w, _)| *w)
    }

    pub fn face(&self, name: &str) -> Style {
        self.faces.get(name).copied().unwrap_or_default()
    }

    /// The layer called `name`, created on top of the others if new.
    /// The current buffer's own layer `name`, made if it is new.
    pub fn buffer_layer_mut(&mut self, name: &str) -> &mut Layer {
        let layers = self.buffer_layers.entry(self.current).or_default();
        let i = match layers.iter().position(|l| l.name == name) {
            Some(i) => i,
            None => {
                layers.push(Layer {
                    name: name.to_string(),
                    ..Layer::default()
                });
                layers.len() - 1
            }
        };
        &mut layers[i]
    }

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
