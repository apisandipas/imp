---
type: Effort
status: done
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
- [x] The other callers (`api.rs`, `lib.rs`, `complete.rs`, `crdt.rs`, `lsp.rs`) move onto the accessors, with `buffer_mut()`, `cursor()`/`set_cursor()`, `scroll()`/`set_scroll()` and `window_buffer(id)` added for them, and `buffer`, `cursor`, `scroll`, `hscroll`, `parked`, `current`, `windows` and `current_window` become private to `editor.rs`.
- [x] One map: `buffers` replaces `buffer` and `parked`, windows keep their own scroll, `buffer_by_id`/`buffer_by_id_mut`/`buffer_and_cursor_mut` lose their branches on the current buffer, and `switch_to`, `focus_window`, `kill_buffer` and the client views move fewer things around. The bench is no slower; `crates/imp-server/CONTEXT.md` says where buffer and window state live.

## Notes

- Nothing in the buffers-and-windows spec's behaviour changed; the existing tests cover it, the daemon's per-client views included.
- The bench on a 100,000-line buffer, before and after: `j` 0.22 and 0.23 ms, `x` 0.27 and 0.27, `dd` 0.32 and 0.32, `ihello<esc>` 0.99 and 1.01; within run-to-run noise.
- Two places in `editor.rs` still ask whether a window or buffer is current, for the cursor only: `window_view` and `buffer_and_cursor_mut`. The current window's cursor is a plain field because it moves with every key; the others' are marks, so edits keep them in place. No caller outside `editor.rs` asks.
- `Editor::new(buffer)` is the only way to make an editor: `Editor::default()` has no buffer.
