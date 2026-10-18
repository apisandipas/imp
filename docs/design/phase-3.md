# Phase 3 design: editor infrastructure

Written at the start of the phase; the Outcome section records what
changed. 3.1 (buffers) was done in Phase 2 and 3.3's styling in Phase 1.

## Order

1. Windows and splits (3.2).
2. Display: Unicode width and soft wrap (3.4).
3. Frame diffs (the rest of 3.3).
4. Background work: an event loop with timers and jobs (3.7).
5. File handling: atomic saves, external changes, line endings,
   encodings, backups and autosave (3.8).
6. The daemon and socket transport (3.5), then remote use (3.6).

Background work comes before the daemon because both change the server's
main loop; doing the loop once, as "one channel of events", serves both.

## Windows (3.2)

Rust owns the layout: a tree of splits (rows or columns of children, sized
by weight) with windows at the leaves. A window shows a buffer and has its
own scroll; its cursor is a buffer mark named for the window, so edits made
through another window move it correctly. The focused window's cursor is
still `Editor.cursor`, and its buffer still `Editor.buffer`, so every
existing primitive keeps working.

The screen is Vim's `laststatus=2`, `cmdheight=1`: each window has its own
status line, and the bottom row is the message line (or the command line
while typing). Vertical splits are separated by a `│` column.

Primitives: `window-list`, `current-window`, `split-window!` (`'below` or
`'right`), `close-window!`, `focus-window!`, `window-in-direction`
(`'left 'right 'up 'down`), `only-window!`, `resize-window!`,
`equalize-windows!`, `window-buffer`. Scheme: `C-w s v w W h j k l c q o n
= + - < >`, `:sp`, `:vs`, `:new`, `:vnew`, `:close`, `:only`, `:q` closing a
window when there are several, and `SPC w`.

## Display (3.4)

The renderer measures with `unicode-width`: wide chars take two cells, and
combining marks none. Soft wrap is the `wrap` option (on by default, as in
Vim); `gj`/`gk` move by display lines when it is on, and `j`/`k` still by
buffer lines. Without wrap, lines scroll sideways as now.

## Frame diffs (3.3)

The server remembers the last frame it sent each client and sends only the
rows that changed (`ServerMsg::Patch`), plus the cursor. The terminal
client redraws only those rows, which also removes flicker.

## Background work (3.7)

The server's loop reads one channel of events: client messages, timer
ticks, and job output. Only the loop's thread touches the editor and the
Steel VM; other threads only post events. Scheme gets:

- `(run-after! ms thunk)` and `(run-every! ms thunk)` → id, and
  `(cancel-timer! id)`.
- `(start-job! command input on-output on-exit)` → id: runs a process,
  streams its output back as events, and calls Scheme on the loop thread.

Uses in this phase: which-key after a short delay instead of at once,
checking files for outside changes, autosave. LSP (4.2) will be built on
jobs.

## File handling (3.8)

- Saves are atomic: write a temporary file beside the target, then rename,
  keeping the file's permissions. Optional `backup` keeps `FILE~`.
- On open, CRLF line endings are detected and converted, and written back
  as CRLF (`fileformat`); a UTF-8 BOM is kept; invalid UTF-8 opens as
  Latin-1 and is written back as Latin-1 (`fileencoding`).
- Outside changes: the file's modification time is checked on a timer and
  when entering a buffer. An unmodified buffer reloads (`autoread`); a
  modified one gets a warning, and `:w` refuses to overwrite until `:w!`.
- Autosave: modified buffers are copied every `autosave-interval` seconds
  to the state directory; `:recover` restores one.

## Daemon (3.5) and remote use (3.6)

`imp FILE` stays standalone, as the owner decided. `imp --daemon` runs the
editor with no terminal, listening on a Unix socket
(`$XDG_RUNTIME_DIR/imp/default.sock`). `imp --connect [FILE...]` attaches a
terminal to it and opens the files there. Several clients can attach; each
gets frames at its own size. In a client, `:q` detaches that client and
the daemon keeps running; `:kill-server` stops it.

Messages are JSON lines (serde), easy to read when debugging. The
transport is a byte stream, so remote use needs no new protocol: `imp
--bridge` relays stdin/stdout to the local daemon's socket, and `imp
--connect --via 'ssh host imp --bridge'` runs a client here against a
daemon there.
