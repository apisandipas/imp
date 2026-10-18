//! The Rust functions Scheme can call.
//!
//! This is the boundary from the design: Rust owns data and speed, Scheme owns
//! behavior. Everything here is a primitive -- read the buffer, change it,
//! move the cursor, report state. What a key *means* is decided in Scheme.
//!
//! Offsets and counts are `isize` because Steel integers are signed; negative
//! values clamp to zero.

use imp_core::CursorShape;
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use crate::editor;

fn clamp(n: isize) -> usize {
    n.max(0) as usize
}

pub fn register(engine: &mut Engine) {
    // Reading the buffer.
    engine.register_fn("buffer-length", || {
        editor::with(|e| e.buffer.len() as isize)
    });
    engine.register_fn("buffer-char-at", |offset: isize| {
        editor::with(|e| e.buffer.char_at(clamp(offset)))
    });
    // Steel has no char-alphabetic?, and Unicode classification belongs here
    // anyway. Word chars are letters, digits and underscore, as in Vim.
    engine.register_fn("char-word?", |c: char| c.is_alphanumeric() || c == '_');
    engine.register_fn("buffer-substring", |start: isize, end: isize| {
        editor::with(|e| e.buffer.slice(clamp(start), clamp(end)))
    });
    engine.register_fn("buffer-line-count", || {
        editor::with(|e| e.buffer.line_count() as isize)
    });
    engine.register_fn("buffer-line-length", |line: isize| {
        editor::with(|e| e.buffer.line_len(clamp(line)) as isize)
    });
    engine.register_fn("line-col->offset", |line: isize, col: isize| {
        editor::with(|e| e.buffer.line_col_to_offset(clamp(line), clamp(col)) as isize)
    });
    engine.register_fn("offset->line", |offset: isize| {
        editor::with(|e| e.buffer.offset_to_line(clamp(offset)) as isize)
    });
    engine.register_fn("offset->col", |offset: isize| {
        editor::with(|e| e.buffer.offset_to_col(clamp(offset)) as isize)
    });
    engine.register_fn("buffer-modified?", || {
        editor::with(|e| e.buffer.is_modified())
    });
    engine.register_fn("buffer-name", || {
        editor::with(|e| match e.buffer.path() {
            Some(path) => path.display().to_string(),
            None => "[scratch]".to_string(),
        })
    });

    // Changing the buffer.
    engine.register_fn("buffer-insert!", |offset: isize, text: String| {
        editor::with(|e| e.buffer.insert(clamp(offset), &text))
    });
    engine.register_fn("buffer-delete!", |start: isize, end: isize| {
        editor::with(|e| e.buffer.delete(clamp(start), clamp(end)))
    });
    engine.register_fn("undo-boundary!", || {
        editor::with(|e| e.buffer.undo_boundary())
    });
    engine.register_fn("undo!", || editor::with(|e| e.buffer.undo()));
    engine.register_fn("redo!", || editor::with(|e| e.buffer.redo()));
    engine.register_fn("save!", || {
        editor::with(|e| match e.buffer.save() {
            Ok(()) => true,
            Err(err) => {
                e.status = format!("save failed: {err}");
                false
            }
        })
    });

    // The cursor.
    engine.register_fn("cursor", || editor::with(|e| e.cursor as isize));
    engine.register_fn("set-cursor!", |offset: isize| {
        editor::with(|e| e.cursor = clamp(offset).min(e.buffer.len()))
    });

    // Telling the user what's going on.
    engine.register_fn("set-status!", |text: String| {
        editor::with(|e| e.status = text)
    });
    engine.register_fn("set-mode-name!", |name: String| {
        editor::with(|e| e.mode_name = name)
    });
    engine.register_fn("set-cursor-shape!", |shape: String| {
        editor::with(|e| {
            e.cursor_shape = match shape.as_str() {
                "bar" => CursorShape::Bar,
                _ => CursorShape::Block,
            }
        })
    });
    engine.register_fn("quit!", || editor::with(|e| e.quit = true));
}
