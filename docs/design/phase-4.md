# Phase 4 design: IDE features through protocols

Written at the start of the phase; the Outcome section records what
changed.

## Principle

Protocol plumbing and parsing live in Rust (tree-sitter, JSON, message
framing, sockets); what the features *do* (which keys, what a diagnostic
looks like, how a rename is applied) lives in Scheme, so it can be
redefined like everything else. LSP and DAP run as jobs (3.7), so a slow
server never blocks typing.

## Tree-sitter (4.1)

Grammars bundled, as the owner chose: Rust, Scheme, TypeScript and TSX,
JavaScript, Nix, Markdown. Rust keeps a parse tree per buffer and updates
it incrementally: the buffer records each edit (byte offsets and points)
for the parser. A major mode names its language (`set-buffer-language!`).

- **Highlighting**: each grammar's highlight query runs over the visible
  rows only, when drawing. Captures map to faces `syntax.<capture>` with
  fallback (`syntax.function.method` → `syntax.function`), so a theme is a
  set of `set-face!` calls. It is drawn under search and selection.
- **Structural text objects**: two general primitives, the ancestors of a
  position (kind, field and range of each) and the children of a node, let
  Scheme define `af if ac ic aa ia` per language from node kinds. They work
  with every operator and visual mode like other text objects.
- **Indentation**: `smartindent` from the major mode (indent after an
  opening bracket, dedent a closing one), in Scheme. Tree-sitter indent
  queries can replace it later.
- **Folding** is left for later; it needs the renderer to hide lines.

## LSP (4.2)

A server is a job with stdin kept open. Rust adds JSON encoding and
decoding (objects as Steel hashes, arrays as lists) and Content-Length
framing; Scheme does the rest: `initialize` with root detection,
`didOpen`/`didChange` (full text on change, debounced with a timer)/
`didSave`/`didClose`, and:

- diagnostics: underlined in the text, a sign in the gutter, the message
  when the cursor is on the line, `]d`/`[d`, `:diagnostics`;
- hover (`K`), go to definition (`gd`), references (`gr`, through
  completing-read), rename (`SPC c r`, applying workspace edits across
  files), code actions (`SPC c a`), formatting (`SPC c f`);
- completion in insert mode (`C-x C-o` and as you type, in a popup).

Positions are negotiated as UTF-32 (imp's offsets are chars), with a
UTF-16 fallback. Servers are configured per language in Scheme
(`define-language-server!`); defaults cover rust-analyzer,
typescript-language-server, nil, marksman and pyright when installed.
Tests use a scripted fake server.

## DAP (4.3)

The same framing and JSON. Scheme: adapters per language
(`define-debug-adapter!`), launch configurations, breakpoints as gutter
signs (`SPC d b`), continue/step over/in/out (`SPC d c/n/i/o`), the stopped
line highlighted, and stack and variables in popups. Tested with a fake
adapter.

## MCP (4.4)

Off by default, as decided; `(mcp-enable!)` in init.scm turns it on. The
editor listens on a Unix socket private to the user, speaking MCP's
JSON-RPC (newline-delimited JSON). `imp --mcp` relays stdio to it, so an
agent configures `imp --mcp` as a stdio MCP server. With full access, as
decided, the tools are: list buffers, read a buffer or part of it, edit
(replace a range), open, save, the cursor and selection, search, run a
command, diagnostics, and evaluate Scheme. Rust provides the socket
(generic: line-based connections reported as events); the protocol is in
Scheme.

## Progress (for whoever picks this up)

Done and committed on `phase-4`:

- **4.1 tree-sitter**: `src/syntax.rs`, `runtime/syntax.scm`. Parsing has an
  8 ms budget per frame; past that it moves to a background thread
  (`Event::Parsed`), one per buffer at a time. Benchmarked in
  `examples/bench.rs`.
- M-x bound in normal/visual/insert (the owner noticed it missing).
- **LSP groundwork in Rust** (`src/json.rs` + primitives in `api.rs`):
  `json-decode`, `json-encode` (objects ↔ hashes with string keys, arrays
  ↔ lists, null ↔ `'null`; write `(hash)` for `{}`), `lsp-frame`,
  `lsp-take-message` (returns `(decoded-message rest)` or #f; lengths are
  bytes), `path->uri`, `uri->path`, `find-executable`, `absolute-path`.
  Jobs are killed when the server drops.

- **4.2 LSP** (`runtime/lsp.scm`, tests in `tests/lsp.rs` against the
  scripted `tests/fake_lsp.py`): servers per major mode
  (`define-language-server!`), one per (command, root); initialize with
  utf-32/utf-16 negotiation; didOpen/didChange (full text, debounced by
  `lsp-change-delay`)/didSave/didClose (new `buffer-kill` hook, run by
  `:bd`); replies to the usual server requests including
  `workspace/applyEdit`; diagnostics as a `diagnostics` highlight layer
  (between syntax and search), gutter signs (new `set-signs!` primitive:
  a 2-cell column before the numbers, only in buffers that have signs),
  the message on the status line in normal mode (new `status-text`
  primitive so it never overwrites another message), `]d` `[d`
  `:diagnostics`; `lsp-mode` keys `K` `gd` `gr`; `SPC c` (`r` rename, `a`
  code actions incl. commands and resolve, `f` format, `x` diagnostics,
  `R` restart); `:lsp-info :lsp-log :lsp-restart :lsp-stop`; insert-mode
  completion (`C-x C-o`, `C-n`/`C-p` falling back to buffer words, and as
  you type after word or trigger chars, `lsp-complete-delay`), sorted by
  sortText, snippets stripped, `additionalTextEdits` applied,
  `isIncomplete` lists re-requested.
  Checked by hand in a pty with nil (diagnostics) and rust-analyzer
  (diagnostics, hover, definition, completion after `.`).
  Known gaps: diagnostics/sign positions don't move with edits until the
  server republishes; file create/rename/delete in workspace edits is
  refused; no signature help or inlay hints; the completion menu is drawn
  in the bottom popup, not at the cursor (polish pass); dot-repeat of a
  completion replays it as backspaces plus the typed word.

- **Mouse** (asked for by the owner): `runtime/mouse.scm`,
  `ClientMsg::Mouse`, `screen-position`. Click, drag, wheel; `:set
  nomouse`.
- **4.3 DAP** (`runtime/dap.scm`, tests in `tests/dap.rs` against
  `tests/fake_dap.py`): adapters per major mode
  (`define-debug-adapter! mode command adapter-id launch-proc`; lldb-dap
  for Rust/C/C++ asking for the program with Cargo's debug build
  suggested, debugpy for Python); breakpoints as marks (they follow
  edits) with `●` signs; gutter signs now merge by priority
  (`set-sign-source!` in core.scm: diagnostics 10, breakpoints 20, the
  stopped line 30); the stopped line highlighted (`debug` layer, face
  `debug-line`) and marked `→`; `SPC d` d/c n i o p q s v e b B O and
  `<f5> <f9> <f10> <f11>`. Checked by hand with lldb-dap: breakpoint,
  stop, locals, step.
  Known gaps: one session at a time; stdio adapters only (codelldb and
  js-debug need TCP); no conditional breakpoints, watches or expanding
  nested variables beyond `SPC d e`; lldb shows Rust `String` as a raw
  struct (no Rust formatters loaded).

### After LSP

- **4.4 MCP**: opt-in `(mcp-enable!)`; a Unix socket (Rust: generic
  line-based connections as events) speaking MCP JSON-RPC lines; `imp
  --mcp` relays stdio to it. Tools: list/read/edit/open/save buffers,
  cursor and selection, search, run command, diagnostics, eval Scheme.
- **Cosmetic polish pass** (the owner asked for one after seeing Phases
  1–3): status line design, popup/which-key/completion look (a border or
  title, the selection), separators, gutter, a coherent color theme.
- Then Phase 5 (prototype behind cargo features, as decided) and 6.
