# imp-core

Types the server and every client share. Clients depend on this crate, never on `imp-server` ([[0008-crates-follow-the-client-server-boundary]]).

- `buffer.rs`: rope text (ropey), snapshot undo, marks that follow edits.
- `fileio.rs`: CRLF, BOM and Latin-1 round trips, atomic writes, disk stamps.
- `protocol.rs`: `ClientMsg` and `ServerMsg`, `Frame` and `Patch`, as JSON lines over a socket.

## Protocol

- Clients send `Key` (Vim-notation names: `"j"`, `"<esc>"`, `"C-r"`, `"M-x"`), `Resize`, `Open`, `Mouse` (with `fine`, hundredths of a cell), and describe themselves: `Hello { heights: true }` from a client that draws text at different sizes, `Cell { width }` (hundredths of a logical pixel) from one with real cell widths. The terminal sends neither.
- The server replies with a whole `Frame` (rows of styled spans and the cursor), then `Patch`es of changed rows, or `Quit`. For a client that draws heights, a window's text comes as a `WindowBlock` of `BlockRow`s and those cells of `Frame::rows` are left blank; other clients get every height stripped.
- Each `Frame` carries the window `appearance` (font, padding, opacity, divider) with the `normal` face's background.

## Limits

- Undo stores whole-text snapshots, and marks aren't restored by undo (they're clamped into the text). [#5](https://github.com/apisandipas/imp/issues/5)
