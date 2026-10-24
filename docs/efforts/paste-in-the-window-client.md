---
type: Effort
status: planned
specs: ["[[spec/terminals]]"]
issue: https://github.com/apisandipas/imp/issues/46
frozen:
  docs/specs/terminals.md: 7b43584e6e0e
---
# Paste in the window client

Paste the clipboard in `imp --gui` on `S-<insert>` and `C-S-v` (`Cmd-v` on macOS).

## Approach

The window client recognises the paste keys before naming them, reads the clipboard itself, and sends the text as the `ClientMsg::Paste` the terminal client already sends, so everything `imp-handle-paste` does applies unchanged. The client reads the clipboard rather than the server because with `--connect` the server may be on another machine, and the clipboard wanted is the one beside the window. It reuses the server crate's `clipboard` module (the same tools as the `"+` register), made public; the GUI already depends on `imp-server`, so no new dependency. An empty paste, which is what the client sends when no tool gives text, shows a message instead of doing nothing.

## Tasks

- [ ] `keys::is_paste` in `crates/imp-gui/src/keys.rs` says whether a key and modifiers are a paste: `S-<insert>`, `C-S-v`, and `Cmd-v` on macOS, but not `C-v`; with unit tests.
- [ ] `imp-handle-paste` shows a message for an empty paste and changes nothing, with a test in `crates/imp-server/tests/paste.rs`.
- [ ] The window client sends `ClientMsg::Paste` with the clipboard's text (empty if none) on a paste key instead of the key; `imp_server::clipboard` made public. Checked by hand in `imp --gui`: the REPL, insert, normal and the command line.
