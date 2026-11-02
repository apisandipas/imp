//! Shared buffers (crdt.rs, feature `crdt`).

use steel::rerrs::SteelErr;
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use super::{clamp, fail};
use crate::{crdt, editor};

/// The text of buffer `buf`.
fn text(buf: usize) -> Result<String, SteelErr> {
    editor::with(|e| e.buffer_by_id(buf).map(|b| b.text()))
        .ok_or_else(|| fail(format!("no buffer {buf}")))
}

pub(super) fn register(engine: &mut Engine) {
    // Starts mirroring buffer BUF; its text so far is the first change.
    engine.register_fn("crdt-share!", |buf: isize| {
        let buf = clamp(buf);
        crdt::share(buf, &text(buf)?).map_err(fail)
    });
    engine.register_fn("crdt-unshare!", |buf: isize| crdt::unshare(clamp(buf)));
    engine.register_fn("crdt-shared?", |buf: isize| crdt::shared(clamp(buf)));
    // The update since the last sync, or #f if nothing changed.
    engine.register_fn("crdt-sync!", |buf: isize| {
        let buf = clamp(buf);
        crdt::sync(buf, &text(buf)?).map_err(fail)
    });
    // Applies a remote update to buffer BUF.
    engine.register_fn("crdt-apply!", |buf: isize, update: String| {
        let buf = clamp(buf);
        let edits = crdt::apply(buf, &text(buf)?, &update).map_err(fail)?;
        editor::with(|e| {
            if let Some((buffer, cursor)) = e.buffer_and_cursor_mut(buf) {
                crdt::apply_edits(buffer, cursor, &edits);
            }
        });
        Ok::<_, SteelErr>(())
    });
    // What this side has, for a peer to send what it lacks.
    engine.register_fn("crdt-state", |buf: isize| {
        crdt::state(clamp(buf)).map_err(fail)
    });
    // Everything a peer with STATE ("" for nothing) lacks, as an update.
    engine.register_fn("crdt-diff", |buf: isize, state: String| {
        crdt::diff(clamp(buf), &state).map_err(fail)
    });
    engine.register_fn("crdt-available?", || cfg!(feature = "crdt"));
}
