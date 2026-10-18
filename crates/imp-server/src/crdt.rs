//! Shared buffers (feature `crdt`; docs/design/phase-5.md).
//!
//! A shared buffer keeps a yrs (Yjs) text document beside it as a mirror.
//! The buffer is still the rope and is edited as always. Syncing compares
//! it with the mirror and records the difference as one yrs change, so no
//! edit path needs a hook. A remote update is applied to the mirror, and
//! the delta it produces is applied to the buffer as ordinary edits, so
//! marks, the cursor and the syntax tree follow.
//!
//! Updates and states travel as base64, so they fit on one line of a
//! socket. Without the feature the primitives still exist and say so.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use crate::editor;

pub fn register(engine: &mut Engine) {
    // Starts mirroring buffer BUF; its text so far is the first change.
    engine.register_fn("crdt-share!", |buf: isize| {
        let buf = buf.max(0) as usize;
        let text = editor::with(|e| e.buffer_by_id(buf).map(|b| b.text()))
            .ok_or_else(|| format!("no buffer {buf}"))?;
        imp::share(buf, &text)
    });
    engine.register_fn("crdt-unshare!", |buf: isize| {
        imp::unshare(buf.max(0) as usize)
    });
    engine.register_fn(
        "crdt-shared?",
        |buf: isize| imp::shared(buf.max(0) as usize),
    );
    // The update since the last sync, or #f if nothing changed.
    engine.register_fn("crdt-sync!", |buf: isize| {
        let buf = buf.max(0) as usize;
        let text = editor::with(|e| e.buffer_by_id(buf).map(|b| b.text()))
            .ok_or_else(|| format!("no buffer {buf}"))?;
        imp::sync(buf, &text)
    });
    // Applies a remote update to buffer BUF.
    engine.register_fn("crdt-apply!", |buf: isize, update: String| {
        let buf = buf.max(0) as usize;
        let text = editor::with(|e| e.buffer_by_id(buf).map(|b| b.text()))
            .ok_or_else(|| format!("no buffer {buf}"))?;
        let edits = imp::apply(buf, &text, &update)?;
        editor::with(|e| {
            if let Some((buffer, cursor)) = e.buffer_and_cursor_mut(buf) {
                apply_edits(buffer, cursor, &edits);
            }
        });
        Ok::<_, String>(())
    });
    // What this side has, for a peer to send what it lacks.
    engine.register_fn("crdt-state", |buf: isize| imp::state(buf.max(0) as usize));
    // Everything a peer with STATE ("" for nothing) lacks, as an update.
    engine.register_fn("crdt-diff", |buf: isize, state: String| {
        imp::diff(buf.max(0) as usize, &state)
    });
    engine.register_fn("crdt-available?", || cfg!(feature = "crdt"));
}

/// A change to the mirror's text, in bytes: delete `delete` bytes at
/// `at`, then insert `insert` there.
#[derive(Debug, PartialEq)]
pub struct Edit {
    pub at: usize,
    pub delete: usize,
    pub insert: String,
}

/// Applies edits in order; each one's offset counts the ones before it.
/// The cursor moves with text changed before it, and stays put for text
/// inserted right at it.
fn apply_edits(buffer: &mut imp_core::Buffer, cursor: &mut usize, edits: &[Edit]) {
    if edits.is_empty() {
        return;
    }
    // Remote changes are their own undo step, not part of the local one.
    buffer.undo_boundary();
    for edit in edits {
        let start = buffer.byte_to_char(edit.at);
        if edit.delete > 0 {
            let end = buffer.byte_to_char(edit.at + edit.delete);
            buffer.delete(start, end);
            if *cursor > start {
                *cursor -= (*cursor).min(end) - start;
            }
        }
        if !edit.insert.is_empty() {
            buffer.insert(start, &edit.insert);
            if *cursor > start {
                *cursor += edit.insert.chars().count();
            }
        }
    }
    buffer.undo_boundary();
    *cursor = (*cursor).min(buffer.len());
}

/// Bytes `old` and `new` share at the start and (not overlapping) at the
/// end, on char boundaries.
pub(crate) fn common_ends(old: &str, new: &str) -> (usize, usize) {
    let prefix = old
        .char_indices()
        .zip(new.chars())
        .find(|((_, a), b)| a != b)
        .map_or(old.len().min(new.len()), |((i, _), _)| i);
    let limit = old.len().min(new.len()) - prefix;
    let mut suffix = 0;
    for (a, b) in old.chars().rev().zip(new.chars().rev()) {
        if a != b || suffix + a.len_utf8() > limit {
            break;
        }
        suffix += a.len_utf8();
    }
    (prefix, suffix)
}

#[cfg(not(feature = "crdt"))]
mod imp {
    use super::Edit;

    const MISSING: &str = "imp was built without the crdt feature";

    pub fn share(_: usize, _: &str) -> Result<(), String> {
        Err(MISSING.into())
    }
    pub fn unshare(_: usize) {}
    pub fn shared(_: usize) -> bool {
        false
    }
    pub fn sync(_: usize, _: &str) -> Result<Option<String>, String> {
        Err(MISSING.into())
    }
    pub fn apply(_: usize, _: &str, _: &str) -> Result<Vec<Edit>, String> {
        Err(MISSING.into())
    }
    pub fn state(_: usize) -> Result<String, String> {
        Err(MISSING.into())
    }
    pub fn diff(_: usize, _: &str) -> Result<String, String> {
        Err(MISSING.into())
    }
}

#[cfg(feature = "crdt")]
mod imp {
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    use base64::engine::general_purpose::STANDARD;
    use base64::Engine as _;
    use yrs::types::Delta;
    use yrs::updates::decoder::Decode;
    use yrs::updates::encoder::Encode;
    use yrs::{
        Any, Doc, GetString, Observable, Options, Out, ReadTxn, StateVector, Text, TextRef,
        Transact, Update,
    };

    use super::{common_ends, Edit};

    struct Shared {
        doc: Doc,
        text: TextRef,
        /// Local changes not yet handed out by `sync`.
        pending: Vec<Vec<u8>>,
        /// What the observer saw in the last transaction.
        deltas: Arc<Mutex<Vec<Delta>>>,
    }

    thread_local! {
        static SHARED: RefCell<HashMap<usize, Shared>> = RefCell::new(HashMap::new());
    }

    fn with<T>(buf: usize, f: impl FnOnce(&mut Shared) -> Result<T, String>) -> Result<T, String> {
        SHARED.with(|s| match s.borrow_mut().get_mut(&buf) {
            Some(shared) => f(shared),
            None => Err(format!("buffer {buf} isn't shared")),
        })
    }

    fn decode(text: &str) -> Result<Vec<u8>, String> {
        STANDARD
            .decode(text.trim())
            .map_err(|e| format!("bad base64: {e}"))
    }

    pub fn share(buf: usize, text: &str) -> Result<(), String> {
        let doc = Doc::with_options(Options {
            offset_kind: yrs::OffsetKind::Bytes,
            ..Options::default()
        });
        let ytext = doc.get_or_insert_text("text");
        let deltas = Arc::new(Mutex::new(Vec::new()));
        let seen = deltas.clone();
        ytext.observe("imp", move |txn, event| {
            seen.lock()
                .unwrap()
                .extend(event.delta(txn).iter().cloned());
        });
        let mut shared = Shared {
            doc,
            text: ytext,
            pending: Vec::new(),
            deltas,
        };
        record_local(&mut shared, text);
        SHARED.with(|s| s.borrow_mut().insert(buf, shared));
        Ok(())
    }

    pub fn unshare(buf: usize) {
        SHARED.with(|s| s.borrow_mut().remove(&buf));
    }

    pub fn shared(buf: usize) -> bool {
        SHARED.with(|s| s.borrow().contains_key(&buf))
    }

    /// Records how `text` differs from the mirror as one change.
    fn record_local(shared: &mut Shared, text: &str) {
        let old = shared.text.get_string(&shared.doc.transact());
        if old == text {
            return;
        }
        let (prefix, suffix) = common_ends(&old, text);
        let update = {
            let mut txn = shared.doc.transact_mut();
            let removed = old.len() - prefix - suffix;
            if removed > 0 {
                shared
                    .text
                    .remove_range(&mut txn, prefix as u32, removed as u32);
            }
            let inserted = &text[prefix..text.len() - suffix];
            if !inserted.is_empty() {
                shared.text.insert(&mut txn, prefix as u32, inserted);
            }
            txn.encode_update_v1()
        };
        // The observer saw our own change; it's already in the buffer.
        shared.deltas.lock().unwrap().clear();
        shared.pending.push(update);
    }

    pub fn sync(buf: usize, text: &str) -> Result<Option<String>, String> {
        with(buf, |shared| {
            record_local(shared, text);
            if shared.pending.is_empty() {
                return Ok(None);
            }
            let pending = std::mem::take(&mut shared.pending);
            let update = if pending.len() == 1 {
                pending.into_iter().next().unwrap()
            } else {
                yrs::merge_updates_v1(pending).map_err(|e| e.to_string())?
            };
            Ok(Some(STANDARD.encode(update)))
        })
    }

    /// Applies a remote update and returns the edits that bring `text`
    /// (the buffer) up to date. Local changes are recorded first, so the
    /// mirror matches the buffer the edits apply to; the next `sync` hands
    /// them out.
    pub fn apply(buf: usize, text: &str, update: &str) -> Result<Vec<Edit>, String> {
        let bytes = decode(update)?;
        let update = Update::decode_v1(&bytes).map_err(|e| format!("bad update: {e}"))?;
        with(buf, |shared| {
            record_local(shared, text);
            shared
                .doc
                .transact_mut()
                .apply_update(update)
                .map_err(|e| format!("bad update: {e}"))?;
            let deltas = std::mem::take(&mut *shared.deltas.lock().unwrap());
            let mut edits = Vec::new();
            let mut at = 0;
            for delta in deltas {
                match delta {
                    Delta::Retain(n, _) => at += n as usize,
                    Delta::Deleted(n) => edits.push(Edit {
                        at,
                        delete: n as usize,
                        insert: String::new(),
                    }),
                    Delta::Inserted(Out::Any(Any::String(s)), _) => {
                        edits.push(Edit {
                            at,
                            delete: 0,
                            insert: s.to_string(),
                        });
                        at += s.len();
                    }
                    // Only strings go in the text.
                    Delta::Inserted(..) => {}
                }
            }
            Ok(edits)
        })
    }

    pub fn state(buf: usize) -> Result<String, String> {
        with(buf, |shared| {
            Ok(STANDARD.encode(shared.doc.transact().state_vector().encode_v1()))
        })
    }

    pub fn diff(buf: usize, state: &str) -> Result<String, String> {
        let state = if state.trim().is_empty() {
            StateVector::default()
        } else {
            StateVector::decode_v1(&decode(state)?).map_err(|e| format!("bad state: {e}"))?
        };
        with(buf, |shared| {
            Ok(STANDARD.encode(shared.doc.transact().encode_state_as_update_v1(&state)))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn common_ends_stay_on_char_boundaries() {
        assert_eq!(common_ends("abc", "abc"), (3, 0));
        assert_eq!(common_ends("abXc", "abYc"), (2, 1));
        assert_eq!(common_ends("aaa", "aa"), (2, 0));
        assert_eq!(common_ends("é1", "è1"), (0, 1));
        assert_eq!(common_ends("xéy", "xy"), (1, 1));
    }
}
