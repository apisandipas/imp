---
type: Effort
status: active
specs: ["[[spec/buffers-and-windows]]"]
issue: https://github.com/apisandipas/imp/issues/133
frozen:
  docs/specs/buffers-and-windows.md: bc8c82b25ab1
---
# One place for buffers and windows

Keep every buffer in one map and every window's state in its window, so no caller asks "is this the current one?" to find its state. A refactor: nothing a user sees changes.

## Approach

`Editor` keeps the current buffer in `buffer`/`cursor`/`scroll`/`hscroll` and the others in `parked`; the current window's scroll is in the loose fields, the others' in `windows`. Callers branch on `id == e.current_window` or `id == e.current` to find the right one. The work goes a step at a time, each step leaving the tests passing: accessors over the present storage first, then callers moved onto them and the fields made private, then the storage changed behind the accessors, where no caller sees it.

The end state: `buffers` holds every buffer with the cursor and scroll it was last left at; a `Window` holds its buffer, scroll and hscroll, the current window's too; `current` and `current_window` are ids. The current window's cursor stays a plain field, and other windows' cursors stay marks in their buffers (`window_mark`), so edits through another window keep them in place and the keystroke path doesn't look a cursor up by name. `window_view(id)` is the one place that knows the difference. Daemon client views ([[0015-daemon-clients-own-their-windows-and-share-the-typing]]) are swapped as before.

The keystroke path must not slow down: the bench example runs before and after, and both numbers go in the PR.

## Tasks

- [x] Accessors over the present storage: `buffer()`, `current()`, `current_window()`, `set_window_scroll(id, scroll, hscroll)`, and `window_view(id)` giving a window's buffer id, buffer, cursor, scroll and hscroll. Rendering and clicks (`frame`, `draw_window`, `screen_position`, `fold_column_at`, `window_cell`, `window_text_size`, `faces_at`) move onto them, with no branch on the current window left in `render.rs`.
- [ ] The other callers (`api.rs`, `lib.rs`, `complete.rs`, `crdt.rs`, `lsp.rs`) move onto the accessors, with `buffer_mut()`, `cursor()`/`set_cursor()`, `scroll()`/`set_scroll()` and `window_buffer(id)` added for them, and `buffer`, `cursor`, `scroll`, `hscroll`, `parked`, `current`, `windows` and `current_window` become private to `editor.rs`.
- [ ] One map: `buffers` replaces `buffer` and `parked`, windows keep their own scroll, `buffer_by_id`/`buffer_by_id_mut`/`buffer_and_cursor_mut` lose their branches on the current buffer, and `switch_to`, `focus_window`, `kill_buffer` and the client views move fewer things around. The bench is no slower; `crates/imp-server/CONTEXT.md` says where buffer and window state live.
