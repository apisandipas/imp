---
type: Effort
status: active
specs: ["[[spec/live-scheme-and-help]]"]
issue: https://github.com/apisandipas/imp/issues/131
frozen:
  docs/specs/live-scheme-and-help.md: ccb5a072e58a
---
# Primitives by area, one error convention

`api::register` is one function of about 1,840 lines registering 226 primitives, and primitives report failure three ways: most return `Result` (Scheme raises), some return the error as a string value in place of their result (`buffer-open!` gives an id or a string), and a few drop it (`lsp-take-message` turns bad JSON into #f). A refactor: what a user sees stays the same, except that error messages lose the quotes Steel put around them.

## Approach

First a pure move: `api.rs` becomes `api/mod.rs`, which keeps the shared helpers (`clamp`, `writable`, `popup_line`, ...) and calls one `register` per area file (`buffer.rs`, `files.rs`, `window.rs`, `term.rs`, `lsp.rs`, `syntax.rs`, ...). No two primitives share a name, so the order of registration doesn't matter; `wasm`, `crdt` and `kdl` still register last.

Then one error convention. A `Result<_, String>` raises with the message Debug-quoted (`"foo: No such file"`, quotes included), which is why some primitives returned the string instead, so Scheme could show it. A `Result<_, SteelErr>` raises with the message as it is. So every fallible primitive in `api/` returns `Result<_, SteelErr>`, made with one helper, `fail`; the ones that returned their error as a value, or dropped it, raise it instead; and their Scheme callers catch it with `with-handler` and `error-message`, as `write-buffer!` already does for `write-file!`. `lsp-take-message` hands back the message's text undecoded, so the DAP client decodes it inside the handler it already has and a bad message is reported and skipped rather than stopping the stream. `parse-error` and `pattern-error` stay: they are questions whose answer is an error message, not operations that fail.

## Tasks

- [x] Move `register` into `api/`, one file per area, with the shared helpers in `api/mod.rs`; no primitive changes. `crates/imp-server/CONTEXT.md` names the area files, and decision 0005's anchor follows the move.
- [x] `api::fail` makes a `SteelErr`, and every primitive in `api/` that returned `Result<_, String>` returns `Result<_, SteelErr>`, so its message raises unquoted; tests that matched a quoted message are updated.
- [ ] The primitives that returned an error as a value (`buffer-open!`, `directory-entries`, `rename-file!`, `copy-file!`, `make-directory!`, `delete-path!`, `job-start!`, `socket-listen!`, `socket-connect!`, `term-start!`, `set-buffer-language!`) or dropped it (`delete-file!`, `save!`, `lsp-take-message`) raise it; every caller in `runtime/` and `packages/` catches it and says what it said before, with tests for the error paths. The rule goes in `crates/imp-server/CONTEXT.md` and `docs/steel.md`.
