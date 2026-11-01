//! The Rust functions Scheme can call.
//!
//! This is the boundary from the design: Rust owns data and speed, Scheme owns
//! behavior. Everything here is a primitive -- read the buffer, change it,
//! move the cursor, report state. What a key *means* is decided in Scheme.
//!
//! Offsets and counts are `isize` because Steel integers are signed; negative
//! values clamp to zero.
//!
//! Each file registers one area's primitives; this one holds what they share.

use steel::rerrs::{ErrorKind, SteelErr};
use steel::steel_vm::engine::Engine;

use crate::editor::Editor;

mod background;
mod buffer;
mod complete;
mod display;
mod faces;
mod lsp;
mod mouse;
mod search;
mod source;
mod syntax;
mod system;
mod term;
mod ui;
mod window;

pub fn register(engine: &mut Engine) {
    buffer::register(engine);
    system::register(engine);
    source::register(engine);
    window::register(engine);
    background::register(engine);
    ui::register(engine);
    faces::register(engine);
    display::register(engine);
    mouse::register(engine);
    term::register(engine);
    search::register(engine);
    lsp::register(engine);
    complete::register(engine);
    syntax::register(engine);

    crate::wasm::register(engine);
    crate::crdt::register(engine);
    crate::kdl::register(engine);
}

fn clamp(n: isize) -> usize {
    n.max(0) as usize
}

/// A primitive's error, raised in Scheme with `msg` as its message. Every
/// fallible primitive returns `Result<_, SteelErr>` made with this: an
/// `Err(String)` would raise too, but with the message Debug-quoted.
fn fail(msg: impl std::fmt::Display) -> SteelErr {
    SteelErr::new(ErrorKind::Generic, msg.to_string())
}

/// Fails if the current buffer is read-only.
fn writable(e: &Editor) -> Result<(), SteelErr> {
    if e.buffer().read_only {
        Err(fail("E21: Cannot make changes, 'modifiable' is off"))
    } else {
        Ok(())
    }
}
