//! JSON, and the framing and hot paths of the LSP and DAP clients
//! (json.rs, lsp.rs).

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::{clamp, fail};
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
    // JSON and the framing LSP and DAP use (json.rs).
    engine.register_fn("json-decode", |text: String| {
        serde_json::from_str::<serde_json::Value>(&text)
            .map(crate::json::to_steel)
            .map_err(|e| fail(format!("bad JSON: {e}")))
    });
    engine.register_fn("json-encode", |value: SteelVal| {
        crate::json::from_steel(&value)
            .map(|v| v.to_string())
            .map_err(fail)
    });
    engine.register_fn("lsp-frame", |body: String| crate::json::frame(&body));
    // (body rest) for the first whole message in `text`, its body still
    // JSON text for json-decode, so a bad one is an error the caller sees
    // and can step past; or #f.
    engine.register_fn("lsp-take-message", |text: String| {
        crate::json::take_message(&text).map(|(body, rest)| vec![body, rest])
    });
    // The LSP client's hot paths (lsp.rs): server `key`'s output `text`
    // added to what it sent, and the messages now whole, decoded.
    engine.register_fn("lsp-read-messages", |key: String, text: String| {
        crate::lsp::read_messages(&key, &text)
    });
    // The reply to completion request `id` to server `key` is kept in Rust:
    // its result comes as (hash "imp-completion" handle "isIncomplete" b).
    engine.register_fn("lsp-expect-completion!", |key: String, id: isize| {
        crate::lsp::expect_completion(&key, id as i64)
    });
    // Completion request `id`, superseded: its reply comes with a null
    // result, unread.
    engine.register_fn("lsp-drop-completion!", |key: String, id: isize| {
        crate::lsp::drop_completion(&key, id as i64)
    });
    // The menu candidates of completion reply `handle`, at `start` in the
    // current buffer, positions counting in `encoding`.
    engine.register_fn(
        "lsp-completion-candidates",
        |handle: isize, start: isize, encoding: String| {
            editor::with(|e| crate::lsp::candidates(e, handle as i64, clamp(start), &encoding))
        },
    );
    // Item `index` of completion reply `handle`, whole, or #f.
    engine.register_fn("lsp-completion-item", |handle: isize, index: isize| {
        crate::lsp::item(handle as i64, clamp(index))
    });
    engine.register_fn("path->uri", |path: String| crate::json::path_to_uri(&path));
    engine.register_fn("uri->path", |uri: String| crate::json::uri_to_path(&uri));
}
