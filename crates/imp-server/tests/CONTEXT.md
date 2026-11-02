# imp-server tests

Behavior tests drive a real `Server` by feeding keys (`type_keys(&mut s, "dw.")`) and assert text, cursor, status and frame rows. Helpers are in `common/`.

- `type_keys` reads `<` followed by a lowercase letter as a key name (`<esc>`), so send a literal `<` with `s.keys(&["<", "j"])`.
- Tests clear the theme's `normal` background so rows hold only what was drawn, and turn LSP off so installed language servers can't change results; `lsp.rs` turns it on for its fake server (`fake_lsp.py`, and `fake_dap.py` for `dap.rs`).
- CI's temporary paths are long (`/home/runner/work/_temp`), so a test that reads a status line, `:ls` or a menu at 80 columns can pass locally and fail on CI. Widen the screen (`s.set_size(200, 24)`) when a test needs a whole path, and before pushing such a test run `TMPDIR=/tmp/runner/work/_temp tools/check.sh` (make the directory first). Don't use a much longer path: Unix sockets fail past ~108 bytes.
- `help.rs` fails on a runtime function without a docstring or an option without a comment above; `completion.rs` fails on a command M-x can't describe.
- Steel's prelude takes ~0.3 s per server, so the suite takes about half a minute.
- `daemon.rs`: clients share the typing state ([[0015-daemon-clients-own-their-windows-and-share-the-typing]]), so before another client types, call `settle()` on the one that just did. A frame `until` accepts can arrive before that client's last keys are handled, and on a busy CI machine those keys then land in the other client's command line.
