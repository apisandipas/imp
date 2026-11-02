# imp-server

The editor. It owns all state; clients only send input and draw frames ([[0004-client-and-server]]).

- `lib.rs`: `Server`, `run()`, runtime and package loading (`RUNTIME`, `PACKAGES`), `eval()`.
- `editor.rs`: editor state, thread-local: buffers, windows, faces, highlight layers. Every buffer is in one map and every window's buffer and scroll in its `Window`, the current one's too; only ids say which is current. Read a window through `window_view(id)`, the one place that knows the current window's cursor is a field and the others' are marks; don't branch on the current window to find state.
- `events.rs`: the loop's events; timers and jobs. `daemon.rs`: `imp --daemon`, the socket server.
- `api/`: the Rust/Scheme boundary, every primitive Scheme can call, a file per area: `buffer.rs` (the current buffer, the buffer list, undo, marks, the cursor), `system.rs` (files, directories, the environment, shell commands, the clipboard), `source.rs` (loaded Scheme sources, built-in packages), `window.rs` (windows, layout, wrap, line numbers, gutter columns), `background.rs` (timers, jobs, sockets), `ui.rs` (status, command line, popups, floats), `faces.rs` (faces, highlight layers), `display.rs` (folds, signs, change marks, margins, footers, body width), `mouse.rs`, `term.rs`, `search.rs` (search and bracket scans), `lsp.rs` (JSON, LSP and DAP), `complete.rs` and `syntax.rs`. `mod.rs` calls each file's `register` and holds the helpers they share.
- `render.rs`: editor to `Frame`: windows, wrap, Unicode width, gutter, highlights, popups, status lines.
- `layout.rs`: the window split tree. Others: `search.rs` (Vim regex to the `regex` crate), `scan.rs` (bracket and tag scans), `complete.rs` and `fuzzy.rs` (completion stores and matching), `lsp.rs`, `docs.rs`, `syntax.rs`, `term.rs`, `clipboard.rs`, `shell.rs`; `wasm.rs`, `crdt.rs` and `kdl.rs` are behind features.

## How it runs

- Standalone (`imp FILE`), the client spawns `imp_server::run` on a thread, connected by two channels. With `imp --daemon` it listens on a Unix socket; `--connect` clients speak JSON lines and `--bridge` relays stdio for `--via 'ssh host imp --bridge'`.
- Each daemon client has its own windows: a `ClientView` (layout, current window, each window's buffer and scroll) swapped into the `Editor` around its input and its frame; every cursor waits in a window mark meanwhile. Everything else, the typing state included, is shared ([[0015-daemon-clients-own-their-windows-and-share-the-typing]]). State about what a client sees belongs in those swapped fields, or keyed by window id, never in a new Scheme global or `Editor` field that every client would share.
- One loop reads one channel of events: client messages, timers, job output. Only that thread touches the editor and the Steel VM ([[0012-one-thread-owns-the-vm-and-the-editor]]).
- For every key the server calls `(imp-handle-key key)` and for every mouse event `(imp-handle-mouse action button x y)`. Rust has no idea what keys mean.
- Runtime files are embedded with `include_str!`; `IMP_RUNTIME` loads them from disk instead.
- Live redefinition: the server appends `(set! name name)` for every top-level definition of each runtime file, and user code goes through `imp-eval-string` (`runtime/core.scm`), which turns a `define` of an existing name into `set!`. `tests/eval.rs` and `tests/config.rs` check it.

## The API (`api/`)

All positions are char offsets; integers are `isize` and negatives clamp. Primitives cover buffers, changes and undo, files and processes, marks, search, windows and layout, UI (status, popups, command line, signs, margins, faces, highlight layers), background timers and jobs, tree-sitter, JSON and LSP framing, sockets, and the mouse. Help doesn't cover primitives; their arguments are in `api/`, where each is registered. A fallible primitive returns `Result<_, SteelErr>`, its error made with `fail` (`api/mod.rs`), so Scheme raises it with the message as written; an `Err(String)` would raise it Debug-quoted, quotes and all.

Fallible primitives return `Result`: one that can fail raises, and never returns its error as a value in place of its result (an id or a message) or drops it (#f). Scheme that wants to show the error catches it: `(with-handler (lambda (e) (message (error-message e)) #f) (buffer-open! path))`, or `error-text` for one called for its effect. A question whose answer is an error message (`parse-error`, `pattern-error`) isn't a failure.

## Rendering notes

- Text heights: a face can say `height=1.3`. For a client that draws heights, each window is laid out by line height (`line_scale`) and sent as a block; popups opening at the cursor go on the grid row its row ends in. `tests/heights.rs` covers it.
- Side-by-side windows are `Editor::divider()` columns apart: the `window-divider-width` option (logical pixels) over the client's cell width; terminals get one column. Use `e.window_rects()`, not `layout.rects`, so the gap is counted. A wide border is blank with `│` in its middle.
- `line_cells`, `line_indent` and `gutter_width` are the shared layout that drawing, wrap and scrolling use; change them together. A line indent (`set-line-indents!`) is blank cells before every row of a line, set by Scheme for runs of lines (Org's org-indent); the renderer knows nothing of what they mean.
- Clicks don't lay lines out: `draw_window` records each row's line and where its chars went (`DrawnText`, kept on the window), and `screen_position` and `fold_column_at` look the cell up there. A window changed since its last frame (or never drawn) is laid out afresh by `draw_window` itself, so drawing is the only layout to change.

## Limits

- One server per thread: editor state is a `thread_local` because Steel's `register_fn` takes plain functions. Tests must not run two servers at once on one thread.
