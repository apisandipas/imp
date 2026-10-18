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
