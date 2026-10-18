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

### Next: `runtime/lsp.scm` (4.2), planned in detail

Add it to `RUNTIME` in `lib.rs` after `syntax.scm`.

- **Config**: `(define-language-server! 'rust-mode "rust-analyzer"
  '("Cargo.toml" ".git") "rust")` keyed by *major mode* (python has no
  tree-sitter language), with the LSP languageId. Defaults: rust-analyzer;
  `typescript-language-server --stdio` for typescript/tsx/javascript
  (languageIds typescript, typescriptreact, javascript); `nil` for nix;
  `marksman server` for markdown; `pyright-langserver --stdio` for python.
  Start only if `find-executable` finds it and option `lsp` is on.
  `rust-analyzer` and `nil` are installed on the owner's machine.
- **Server state**, keyed by (mode . root): job id (started with input #f
  so stdin stays open), receive buffer string, next request id, pending
  `id -> callback` hash, capabilities, position encoding, initialized flag,
  queue of messages sent before `initialized`.
- **Root**: walk up from the file's directory for the markers.
- **initialize**: offer `general.positionEncodings ["utf-32","utf-16"]`
  (imp offsets are chars = utf-32); honor the server's choice; utf-16 needs
  converting columns via the line text (chars > #xFFFF count 2). Then
  `initialized`, then flush the queue.
- **Sync**: `didOpen` when a buffer gets its major mode (hook
  `major-mode`/`buffer-open`); `didChange` with the full text, debounced
  ~200 ms with `run-after!`/`cancel-timer!` from the `after-change` hook;
  `didSave` from `after-save`; `didClose` from `:bd` (add a
  `buffer-kill` hook there).
- **Incoming**: `lsp-take-message` in a loop on job output. Responses (id +
  result/error) go to the pending callback. Server requests (method + id)
  get replies: `workspace/configuration` → list of nulls,
  `client/registerCapability` and `window/workDoneProgress/create` → null,
  `workspace/applyEdit` → apply, `{applied: true}`. Notifications:
  `textDocument/publishDiagnostics`, `window/showMessage` (message),
  `$/progress` (message with percentage).
- **Diagnostics**: stored per URI; a `diagnostics` highlight layer for the
  current buffer, refreshed on `buffer-enter` (faces `diagnostic.error`,
  `.warning`, `.info`, `.hint`: underline plus color); the message shown on
  the status line when the cursor is on a diagnostic's line (post-command
  hook, only if the status is empty); `]d` `[d`; `:diagnostics` through
  completing-read to jump. Gutter signs need a small renderer addition
  (signs per buffer, a 2-cell column) — do it if cheap.
- **Commands**, in an `lsp-mode` minor mode turned on for attached buffers
  (minor-mode keymaps win over major ones): `K` hover (popup of the
  markdown text), `gd` definition (Location, Location[] or LocationLink[]:
  jump, or completing-read if several), `gr` references
  (completing-read of "file:line: text"), `SPC c r` rename (prompt prefilled
  with the word; apply WorkspaceEdit `changes` or `documentChanges` across
  files, edits sorted last-first, one undo group per buffer), `SPC c a` code
  actions (range = cursor or selection; Command → `workspace/executeCommand`,
  CodeAction with edit → apply, with only data → `codeAction/resolve`),
  `SPC c f` format (TextEdit[] with tabSize/insertSpaces), `SPC c` group in
  leader.scm-style `define-leader!`.
- **Completion** in insert mode: `C-x C-o` and `C-n`/`C-p` (buffer words
  when no server), plus automatic after identifier chars or trigger chars
  (option, ~150 ms delay). A menu in the popup; `C-n C-p <tab>` move, `<ret>`
  accepts (textEdit, else insertText, else label; strip snippet
  placeholders `${1:x}` → x, `$0` → ""), `<esc>` closes; other keys type
  and refilter. Use `*key-interceptor*` and fall through to
  `insert-mode-key!`.
- **Tests**: a scripted fake server in Python (`tests/fake_lsp.py`, skip the
  tests if `python3` is missing) answering initialize, hover, definition,
  references, rename, formatting, codeAction, completion, and publishing a
  diagnostic on didOpen/didChange. Also try rust-analyzer by hand in a pty.

### After LSP

- **4.3 DAP** (same framing and JSON): adapters per language, launch
  configs, breakpoints as gutter signs, continue/step, stopped line
  highlighted, stack and variables popups; fake adapter for tests.
- **4.4 MCP**: opt-in `(mcp-enable!)`; a Unix socket (Rust: generic
  line-based connections as events) speaking MCP JSON-RPC lines; `imp
  --mcp` relays stdio to it. Tools: list/read/edit/open/save buffers,
  cursor and selection, search, run command, diagnostics, eval Scheme.
- **Cosmetic polish pass** (the owner asked for one after seeing Phases
  1–3): status line design, popup/which-key/completion look (a border or
  title, the selection), separators, gutter, a coherent color theme.
- Then Phase 5 (prototype behind cargo features, as decided) and 6.
