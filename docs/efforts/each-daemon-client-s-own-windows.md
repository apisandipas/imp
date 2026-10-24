---
type: Effort
status: active
specs: ["[[spec/daemon]]"]
issue: https://github.com/apisandipas/imp/issues/3
frozen:
  docs/specs/daemon.md: 52dfa8b283fe
---
# Each daemon client's own windows

Each client attached to `imp --daemon` gets its own layout, current window, cursors and scroll; buffers and the typing state stay shared ([[0015-daemon-clients-own-their-windows-and-share-the-typing]]).

## Approach

A `ClientView` in `editor.rs` holds one client's windows, layout and current window. The daemon keeps one per client and swaps it into the `Editor` (`take_view`/`put_view`) before handling that client's input and before drawing its frame, so the renderer's scroll write-back lands in the right client. Every window's cursor, the current one's too while put away, waits in its window mark, so edits through another client move it. A new client gets `new_view`, one window on the buffer of the client last typing; a departed client's marks go with `drop_view`. A window whose buffer was deleted meanwhile shows another when its view is put back. Background work runs in the windows of the client that last sent input. Planned after the first task was built, while the owner was away.

## Tasks

- [x] `ClientView` and `take_view`/`put_view`/`new_view`/`drop_view`; the daemon swaps views around each client's input and frame. Tests in `tests/daemon.rs`: own splits, own cursors moved by another client's edits, `:q` closing a client's window, buffer switches kept apart, a deleted buffer replaced in another client's window.
- [x] Popup windows (`*git…*`, `*grep*`) opened in one client stay in its windows, and `q` there works while another client is attached. Test.
- [ ] `crates/imp-server/CONTEXT.md` says view state lives in the swapped fields; checked by hand by the owner with two clients.
