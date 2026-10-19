# imp: handoff and roadmap

This is everything a new contributor (human or agent) needs to pick up imp:
what it is, what has been decided and why, what exists, what is known to be
rough, and the full list of features discussed, in the order to build them.

Repo: https://github.com/apisandipas/imp. Owner: Bryan Paronto (@apisandipas).

---

## 1. The vision

An editor as flexible as Emacs, designed in 2026. The property that matters
from Emacs is not Lisp itself but this: **almost all of the editor is written
in its own extension language and can be redefined while it runs.** The C core
of Emacs is small; everything else is Elisp you can read, advise or replace.

The test for imp, stated early and worth keeping: *if 80%+ of the editor is not
written in the extension language, we have built VS Code, not Emacs.*

On top of that, imp is **Vim-first** ("evil by default"). Unlike Emacs's Evil,
which retrofits Vim onto a modeless editor, imp builds the modal model into the
core design from day one.

## 2. Decisions already made (don't relitigate without the owner)

| Decision | Choice | Why |
|---|---|---|
| Core language | **Rust** | Ecosystem (ropey, tree-sitter, crossterm, wgpu, tokio), memory safety around third-party code. |
| Extension language | **Steel** (Scheme embedded in Rust, `steel-core` 0.8.3) | Live redefinition, macros, introspection; embeds natively in Rust. Lua and TypeScript were considered and rejected (no macros / not built for live redefinition). |
| Build approach | **Written from scratch, using libraries**, not a fork | Owner explicitly did not want to fork Helix or Lem. Read them as reference only. |
| UI | **Window first** (since 0.1.0-alpha.1), terminal with `--tui` | Built terminal first because it was cheaper; the owner then made the GUI the primary client. `imp` falls back to the terminal when no window can open (no display, SSH). |
| Architecture | **Client/server** | Like `emacs --daemon` / Neovim UIs. Server owns all state; clients are dumb. |
| Rust/Scheme boundary | **Rust owns data and speed; Scheme owns behavior** | Buffers, rendering, parsing in Rust. Every command, keymap and mode in Scheme, including the Vim engine. |
| Editing model | **Vim by default** | Built into the keymap/command model, not bolted on. |
| Name | **imp** (a minor demon: evil + daemon) | `grimoire` was liked but `grim` collides with the owner's Wayland screenshot tool. |
| User config | **`~/.config/imp/init.scm`** (or `$XDG_CONFIG_HOME/imp/init.scm`) | Owner's choice; mirrors Emacs's `init.el`. |
| Crate layout | **Three crates in one workspace**, owner confirmed | Compiler-enforced client/server boundary. |
| Package names | Package `imp-editor`, binary `imp` | `imp` is taken on crates.io; `imp-editor` was free when checked. |

Optional naming theme the owner liked (user-facing names only, never in Rust
internals): commands are "spells", packages are "tomes", the config is your
"grimoire". Not adopted in code yet; ask before using it.

## 3. Current state (end of Phase 6, on `main`)

The whole roadmap is built:
- Phase 1, daily-driver Vim;
- Phase 2, the Emacs half;
- Phase 3, editor infrastructure;
- Phase 4, IDE protocols;
- Phase 5, prototypes behind features;
- Phase 6, the ecosystem packages.

Every step is a separate commit. The phases were built on stacked branches
(`phase-1` ... `phase-6`), since fast-forwarded into `main` and deleted.
Design notes per phase are in `docs/design/`.

### Layout

```
Cargo.toml                 workspace; deps optimized in dev builds (fast tests)
flake.nix                  dev shell + package (both verified)
crates/
  imp-core/                shared types
    src/buffer.rs          rope text, snapshot undo, marks that follow edits
    src/fileio.rs          CRLF/BOM/Latin-1, atomic writes, disk stamps
    src/protocol.rs        ClientMsg, ServerMsg, Frame/Patch, JSON lines
  imp-server/              the editor
    src/lib.rs             Server, run(), runtime loading, eval()
    src/editor.rs          Editor state (thread-local): buffers, windows,
                           faces, highlight layers
    src/layout.rs          the window split tree
    src/events.rs          the event loop's events; timers and jobs
    src/daemon.rs          imp --daemon: the socket server
    src/api.rs             THE Rust->Scheme boundary (~55 primitives)
    src/render.rs          Editor -> Frame: windows, wrap, Unicode width,
                           gutter, highlights, popup, status lines
    src/search.rs          Vim regex syntax -> `regex` crate; search, :s
    src/scan.rs            bracket matching and tag pairing (speed)
    src/clipboard.rs       "+ and "* via wl-copy/xclip/xsel/pbcopy
    src/shell.rs           :! and filters
    tests/vim.rs           ~120 key-driven Vim behavior tests
    tests/render.rs        frame/style tests
    tests/config.rs        init.scm tests
    examples/bench.rs      times commands on a 100k-line buffer
  imp/                     the imp binary (package imp-editor): picks the
                           window or the terminal client
    src/main.rs            the terminal client: crossterm, styled spans
  imp-gui/                 the window client, a library (feature "gui",
                           on by default): winit, wgpu, glyphon
runtime/                   loaded in this order
  core.scm                 evaluation (live redefinition), keymaps, commands,
                           hooks, advice, buffer-locals, options, faces
  vim.scm                  everything Vim, buffers, ex commands (~3300 lines)
  help.scm                 describe-key/function/option, apropos, :help
  completion.scm           completing-read, M-x, find-file, switch-buffer
  leader.scm               SPC leader tree and which-key
  modes.scm                major/minor modes, gc commenting, the REPL
  emacs.scm                the Emacs state (holy bindings)
  packages.scm             use-package!, :packages
  files.scm                autoread, autosave/:recover, fileformat options
  syntax.scm               tree-sitter faces, languages, af/if ac/ic aa/ia
  lsp.scm                  language servers: diagnostics, K gd gr, rename,
                           code actions, format, insert-mode completion
  dap.scm                  debugging: breakpoints, stepping, stack, variables
  mouse.scm                clicks, drag to select, the scroll wheel
  mcp.scm                  MCP: AI agents use the editor (opt-in)
  theme.scm                themes (palettes -> every face), the status line
docs/design/phase-N.md     how each phase was designed, and what changed
```

Size check against the 80% rule: ~5,300 lines of Scheme vs ~2,600 lines of
Rust, and the Rust is the client, protocol, buffer, renderer and the few
primitives that measured too slow in Scheme (bracket/tag scans, fuzzy
matching, regex). Every key's meaning is in Scheme.

### How it works

- `imp` opens a window (`imp_gui::run`) when `imp_gui::display_available()`
  (`$WAYLAND_DISPLAY`/`$DISPLAY`; on macOS, not over SSH) and the event loop
  can be built; otherwise, or with `--tui` or `--via`, it runs the terminal
  client. Window-only flags (`--font`, `--scale`, `--screenshot` ...) are
  an error in the terminal. `cargo build --no-default-features` (and
  `nix build .#tui`) makes a terminal-only imp.
- Standalone (`imp FILE`), the client spawns `imp_server::run` on a thread,
  connected by two `mpsc` channels. With `imp --daemon` the server listens
  on a Unix socket and `imp --connect` clients talk JSON lines
  (`imp --bridge` relays stdio to it, for `--via 'ssh host imp --bridge'`).
  Clients send `ClientMsg::Key("j")` / `Resize` / `Open`; the server replies
  with a `Frame` (rows of styled spans + cursor), then `Patch`es of changed
  rows, or `Quit`.
- The server's loop reads one channel of events: client messages, timers,
  job output. Only that thread touches the editor and the Steel VM.
- For every key the server calls the Scheme function `(imp-handle-key key)`.
  `vim.scm` defines it. Rust has no idea what keys mean.
- Key names: single chars (`"j"`, `" "`), `"<esc>" "<ret>" "<bs>" "<tab>"
  "<del>" "<left>" "<right>" "<up>" "<down>" "<home>" "<end>" "<pageup>"
  "<pagedown>" "<insert>" "<s-tab>" "<f1>"`..., and `"C-r"`, `"M-x"`. Macros
  store keys as text in Vim notation (`<esc>`, `<C-r>`, `<lt>`).
- Runtime `.scm` files are embedded with `include_str!`; `IMP_RUNTIME` (set
  by the dev shell) loads them from disk instead.
- Load order: `core.scm`, `vim.scm`, user `init.scm`, then `(imp-init)`. An
  error in `init.scm` goes to the status line; the editor still starts.
- Scheme errors at runtime are caught and shown as `error: ...`.
- `:eval EXPR` runs Scheme in the live editor (`Server::eval` from Rust).
- **Live redefinition** (the property everything rests on): see "Steel
  gotchas" below for why it needs care. In short, the server appends
  `(set! name name)` for every top-level definition of each runtime file,
  and user code (`init.scm`, `:eval`, eval commands, packages, the REPL)
  goes through `imp-eval-string` in `core.scm`, which turns a `define` of an
  existing name into `set!`, keeps new definitions redefinable, and gives
  names defined later (by a package) a placeholder. `tests/eval.rs` and
  `tests/config.rs` check it.

### The Scheme API (`crates/imp-server/src/api.rs`)

All positions are **char offsets**; integers are `isize` (negatives clamp).

- Buffer: `buffer-length buffer-char-at buffer-substring buffer-line-count
  buffer-line-length line-col->offset offset->line offset->col buffer-name
  buffer-path buffer-modified? char-word?`
- Changing: `buffer-insert! buffer-delete! undo-boundary! undo! redo!`
  (`undo!`/`redo!` return where the text changed, or #f), `save!`
- Files/processes: `write-file! set-buffer-path! read-file file-exists?
  run-shell` (`(code output)`), `clipboard-get clipboard-set!`
- Marks (follow edits): `mark-set! mark-get mark-delete! mark-names`
- Search: `pattern-error search-next substitute! find-open find-close
  tag-pairs-around`
- Cursor/window: `cursor set-cursor! window-top window-height
  set-window-top! set-tab-width!`
- UI: `set-status! set-mode-name! set-mode-line-extra! set-cursor-shape!`
  (`bar block underline`), `set-cmdline! clear-cmdline! set-popup!
  set-popup-selected! set-line-numbers! set-cursorline! window-width quit!`
- Buffers: `buffer-list current-buffer switch-to-buffer! buffer-open!
  buffer-new! buffer-kill! buffer-info buffer-reload! set-buffer-name!
  set-buffer-unmodified! buffer-version`
- Sources and environment: `record-source! source-names source-text
  source-path parse-error getenv current-dir config-dir`
- Completion: `fuzzy-filter list-files`
- Windows: `window-list current-window split-window! close-window!
  focus-window! only-window! window-buffer window-in-direction
  resize-window! equalize-windows! window-text-width set-wrap!
  line-display-col line-col-at-display`
- Background: `timer-start! timer-cancel! job-start! job-send!
  job-close-input! job-kill!` (Scheme wraps them: `run-after! run-every!
  cancel-timer! start-job!`)
- Files: `buffer-changed-on-disk? buffer-forget-disk-change!
  buffer-file-format set-buffer-file-format! set-backup! file-mtime
  write-text-file! delete-file! state-dir`; `kill-server!`
- Styling: `set-face!` (spec like `"fg=#ff8800 bg=blue bold"`),
  `highlight-clear! highlight-add! highlight-pattern!` on named layers
  (`syntax`, `diagnostics`, `search`, `visual` in that order);
  `set-signs!` (gutter signs for the current buffer, a list of
  `(line text face)`); `status-text`. Scheme code should use
  `(set-sign-source! name priority signs)` (core.scm) instead, so sources
  share the column.
- Look: `set-popup!` takes strings or rows of runs (`(text face)`
  lists); `set-popup-place!` ("bottom", or "cursor" with a column shift,
  and a title); `set-statusline!` (formats, see render.rs `status_line`),
  `set-mode-face!`, `set-status-value!` (`%{name}` values).
- Mouse: `screen-position` (`(window offset)` under a screen cell, offset
  #f on a status line); the server calls `(imp-handle-mouse action button
  x y)` for `ClientMsg::Mouse`.
- Tree-sitter: `set-buffer-language! buffer-language syntax-ancestors
  syntax-children syntax-tree` (see syntax.rs / api.rs).
- JSON/LSP: `json-decode json-encode lsp-frame lsp-take-message path->uri
  uri->path find-executable absolute-path`.
- Sockets: `socket-listen! socket-send! socket-close! socket-stop!
  socket-path`; the server calls `imp-socket-opened/line/closed`.
- Searching and output: `search-all` (regex match offsets),
  `buffer-find-all` (literal text), `popup-lines`.

### Extension points in Scheme

- `core.scm`: `(define-key! mode key command)`, `(define-option! name default
  aliases)`, `(option name)`, `(set-option! name value)`, `(watch-option!
  name proc)`, faces.
- `vim.scm`:
  - `(define-motion! key type proc)`: `type` is `'exclusive`, `'inclusive` or
    `'linewise`; `proc` is `(lambda (from count) target-or-#f)`. Works with
    every operator, visual mode, counts and `.`.
  - `(define-char-motion! key type proc)`: motions taking a char (`f`):
    `proc` is `(lambda (from count char) ...)`.
  - `(define-text-object! key proc)`: `proc` returns `(start end linewise?)`
    or #f; used in operator-pending and visual mode.
  - `(define-operator! key proc)`: `(lambda (start end linewise?) ...)`.
  - `(define-char-command! key proc)`: commands taking a char (`r`, `m`, `q`,
    `@`): `(lambda (count char) ...)`.
  - `(define-prefix! key)`: makes `key` the start of longer keys.
  - `(define-ex! name-or-names proc)`: proc takes the parsed command; read it
    with `ex-range ex-range-given? ex-bang? ex-args`.
  - `(begin-change!)` before any change (undo point, `.`/`U` bookkeeping);
    `(with-undo-group thunk)` makes several changes one undo step.
  - `(define-state! state name cursor-shape handler)`: a new editor state
    beside Vim's (emacs.scm uses it).
- Commands and keys: `(define-command! 'name proc)`; `define-key!` takes a
  command name, looked up when the key is pressed. `(run-command 'name)`.
- Hooks: `add-hook! remove-hook! run-hooks`; the editor runs `startup
  after-change before-save after-save post-command insert-enter
  insert-leave mode-change major-mode buffer-enter buffer-open
  buffer-kill option-change`. Advice: `(advice-add! 'fn 'before|'after|'around proc)`,
  `advice-remove!`.
- Leader: `(define-leader! "keys" command "description")`,
  `define-leader-group!`; major modes: `define-mode-leader!` (under SPC m).
- Modes: `define-major-mode! define-minor-mode! define-mode-key!
  define-file-name-mode! set-major-mode! minor-mode-on!`;
  `set-local-option!`, `buffer-local`, `set-buffer-local!`.
- Completion: `(completing-read prompt candidates on-select)`.
- Emacs keys: `(define-key! 'emacs "C-x C-s" 'save-buffer)`.
- Packages: `(use-package! 'name 'git URL 'rev REV 'config thunk)`.
- Background: `(run-after! ms thunk)`, `(run-every! ms thunk)`,
  `(start-job! command input on-output on-exit)` (input `#f` keeps stdin
  open for `job-send!`).
- Options backed by something else: `define-computed-option!`.
- Tree-sitter: `(define-mode-language! 'mode "lang")`,
  `(define-syntax-objects! "lang" function-kinds class-kinds list-kinds)`.
- Language servers: `(define-language-server! 'mode "command args"
  '("root-marker" ...) "languageId")`, or a list of commands to use the
  first installed; option `lsp` turns them off.
- Debug adapters: `(define-debug-adapter! 'mode "command" "adapter-id"
  (lambda (done) (done launch-arguments-hash)))`.
- Sockets: `(listen-socket! path on-open on-line on-close)`.
- MCP: `(mcp-enable!)`, `(define-mcp-tool! "name" "description" schema
  handler)`.
- Themes: `(define-theme! 'name 'parent palette-hash extra-faces)`,
  `(load-theme! 'name)`, `:theme`; options `statusline` and
  `statusline-inactive` (Vim-style `%` items, `%{name}` values).
- Cross-file extension inside the runtime: a later runtime file can't be
  called by name from an earlier one, and a `define` there won't replace an
  earlier file's function for its callers. Use hooks, tables
  (`*extra-states*`) or variables set with `set!` (`*key-interceptor*`,
  `*local-keymaps*`, `*cmdline-key-handler*`).

### Phase 6 packages (on by default)

Each is a runtime file built on the API, with the few primitives it
needed. Details, and what each one leaves out, are in
`docs/design/phase-6.md`.

- **Groundwork** (`special.scm`):
  - generated buffers (`special-mode`, with `q` returning to where you
    were), `menu!` popups and `confirm!`;
  - line drawing with per-line items (`draw-line!`, `line-item`);
  - per-buffer highlights (`buffer-highlight-*`) and read-only buffers
    (`:set nomodifiable`);
  - `write-handler` and `revert-handler` for buffers that aren't files.
  - A buffer's mode keys now come before Vim's operators, motions and
    prefixes, so special buffers can bind `c`, `d`, `q`, `g`.
- **Folding** (`fold.scm`, the renderer, `z` keys in vim.scm): Vim's
  manual folds as mark pairs; `j`, `k` and linewise operators treat a
  closed fold as one line.
- **Git** (`git.scm`, `SPC g g`, `:Git`): a Magit-style status buffer:
  - stage, unstage and discard files and hunks, and commit in a message
    buffer;
  - log, diffs, branches and stashes;
  - fetch, pull and push in the background.
- **Org** (`org.scm`):
  - outline cycling on folds, TODO keywords, checkboxes with cookies;
  - links, aligned tables, new headings with `M-<ret>`, and promote,
    demote and move subtrees;
  - an agenda (`SPC o a`) and capture (`SPC o c`).
- **File browser** (`dired.scm`, `:Ex`, `SPC f d`, `:e DIR`): an oil-style
  editable listing; `:w` shows the renames, deletions and creations and
  asks first.
- **Projects** (`project.scm`):
  - roots from markers, `SPC p f/p/b`;
  - project search (`SPC s p`, `:grep` with rg) into a quickfix list
    (`:copen`, `:cn`, `]q`).
- **Terminals** (`term.rs`, `term.scm`, `:terminal`, `SPC o t`): programs
  on a pty with vt100, in a TERMINAL state. `C-\ C-n` leaves it. ANSI
  colors 0-15 come from the theme (`set-terminal-palette!`).
- **Start screen and recent files** (`start.scm`, from the second polish
  pass): started without a file, imp shows recent files (digits),
  projects (letters) and a few commands; `i` goes to the empty buffer.
  `:start` shows it again, `(set-option! 'start-screen #f)` turns it off.
  Visited files are kept in the state directory; `SPC f r` picks one.

### Phase 5 prototypes

Each began behind a cargo feature or in its own crate. The GUI has since
become the default client (see "How it works"); the others are still off
by default. Details, and what each one
can't do yet, are in `docs/design/phase-5.md`.

- **WASM plugins** (`--features wasm`): `runtime/wasm.scm`,
  `src/wasm.rs`. Core modules with a string ABI, no WASI, fuel and memory
  limits. Plugins become Vim operators (`wasm-operator`), commands
  (`define-wasm-filter!`) and `:[range]wasm`. Example Rust plugin in
  `examples/wasm-plugin`.
- **GPU GUI** (`crates/imp-gui`, now what `imp` opens): winit, wgpu and
  glyphon. Runs the server in-process or attaches with `--connect`.
  `--font`, `--font-size`, `--scale` (or `IMP_GUI_SCALE`), and `C-=` /
  `C--` / `C-0` to zoom. `--screenshot OUT.png` draws off-screen, which is
  how it's tested (Mesa lavapipe). The owner checked it on a real display.
- **Shared buffers** (`--features crdt`): `runtime/collab.scm`,
  `src/crdt.rs`. A yrs document mirrors each shared buffer. `:share
  [NAME]`, `:join [NAME]`, `:unshare` over a Unix socket; the host relays.
  Undo is still local, and other cursors aren't shown.
- **KDL config** (`--features kdl`): `~/.config/imp/config.kdl` loads before
  `init.scm` (`runtime/config.scm`, `src/kdl.rs`). Starter files:
  `examples/config.kdl` and `examples/init.scm`.
- `tools/check.sh` also tests and lints with every feature on, and lints
  the terminal-only build.

### What works

Everything in Phase 1 of the roadmap, matched against Vim's behavior:

- Motions: `h j k l w b e ge W B E gE 0 ^ $ | + - _ <ret> gg G N% { } % H M L
  f F t T ; , n N * # g* g#`, arrows, `<home> <end>`, marks `'x` and
  `` `x``. Vim's rules for exclusive motions and the `dw`/`cw` special cases.
- Text objects: `iw aw iW aW`, quotes, all bracket kinds, `it at`, `ip ap`.
- Operators: `d c y > < gu gU g~ g?`, doubled forms, counts that multiply.
- Commands: `x X D C s S Y p P gp gP r R J gJ ~ C-a C-x u C-r U . & ZZ ZQ
  C-g i a I A o O gi gI` and counts on inserts and pastes.
- Visual: `v V C-v`, `o O gv`, operators, text objects, `I A c r J p u U ~ >
  <`, `.` over the same size of region, block `$`.
- Insert: autoindent, expandtab-aware `<tab>`, `C-w C-u C-h C-t C-d C-r C-o`,
  `<del> <home> <end> <up> <down>`; Replace mode with `<bs>` restore.
- Search: `/ ? n N * #`, incremental, highlighted (`:noh`), as a motion
  (`d/foo`), smartcase, Vim regex syntax.
- Registers `"a-z "A-Z "0-9 "- "_ ". ": "/ "% "+ "*`, `clipboard=unnamedplus`,
  `"1p..`. Macros `q @ @@ @:`; a failing key stops a macro.
- Marks `a-zA-Z ' . ^ [ ] < >`, jump list `C-o C-i`, scrolling `C-d C-u C-f
  C-b C-e C-y zt zz zb z<ret> z. z-`.
- Ex: ranges (`. $ N 'x /pat/ ?pat? %` and offsets), `:w [file] :w! :sav :q
  :wq :x :qa` (no `:e` until buffers exist), `:s` (with `g i I`, groups, `&`, `\r`),
  `:d :y :m :t :> :< :j :pu :k :p :nu :sort :normal :g :v :! :r :u :red :noh
  :set :marks :reg :jumps :delm :eval`; command-line history, editing keys,
  `C-r`, `<tab>` completion of command names.
- Options: `tabstop shiftwidth expandtab autoindent wrapscan hlsearch
  incsearch clipboard` via `:set` (with `no`, `?`, `!`, `=`).

Phase 2 adds:

- Buffers: `:e :e! :enew :ls :b :bn :bp :bd C-^ :wa :qa`, each with its own
  cursor; jumps cross buffers.
- Live Scheme: `:eval`, `:source`, eval form/top-level form/region/buffer,
  `M-:`, `:messages`, and a `*scheme*` REPL buffer (`:repl`, `SPC e i`).
- Help from the source: `describe-key` (press keys, see the binding form and
  its comment), `describe-function/option/command`, `apropos`,
  `find-definition`, `:help`; Scheme buffers have `K` and `gd`.
- Hooks, advice, named commands.
- Completion (orderless fuzzy) for M-x, find-file (gitignore-aware),
  switch-buffer, describe-*.
- SPC leader with which-key (Doom-like tree: files, buffers, eval, help,
  search, toggles, quit, SPC m for the major mode).
- Major modes for ~20 languages (indentation, commentstring), minor modes,
  `:setlocal`, `:mode`, and `gc` commenting.
- An Emacs state (C-z) with mark/region, kill ring, C-u, isearch, C-x keys.
- Packages via `use-package!` (local or git, pinned), `:packages`.
- Line numbers (`number`, `relativenumber`, hybrid), `cursorline`,
  horizontal scrolling for long lines.

Phase 3 adds:

- Windows: `C-w s v n w W h j k l c q o = + - < >`, `:sp :vs :new :vnew
  :close :only`, `SPC w`; each window has its own status line.
- Soft wrap (on by default, as in Vim), Unicode display width, `gj`/`gk`
  by screen rows.
- Frame diffs: only changed rows are sent and redrawn.
- Timers and jobs; which-key waits `which-key-delay` (300 ms).
- Atomic saves, `backup`, CRLF/BOM/Latin-1 round trips, `autoread`, `:w`
  refusing to overwrite outside changes without `!`, autosave and
  `:recover`.
- The daemon (`--daemon`, `--connect`, `--bridge`, `--via`), `:kill-server`.

Phase 4 adds (details in `docs/design/phase-4.md`):

- Tree-sitter (Rust, Scheme, TS/TSX, JS, Nix, Markdown): highlighting
  through `syntax.*` faces, `af if ac ic aa ia`, smartindent.
- LSP: diagnostics (underline, gutter sign, status-line message, `]d [d
  :diagnostics`), `K gd gr`, `SPC c r/a/f`, completion in insert mode
  (`C-x C-o`, `C-n C-p`, and as you type). Defaults for rust-analyzer,
  typescript-language-server, nil, marksman, pyright, used when installed.
  Pull diagnostics (`textDocument/diagnostic`, `workspace/diagnostic/refresh`)
  as well as pushed ones. TypeScript tries tsgo (`tsgo --lsp`), then
  typescript-language-server, then `tsc --lsp` (TypeScript 7's `tsc`; older
  ones have no `--lsp`).
- Debugging (DAP): `SPC d` (`d` start/continue, `b` breakpoint, `n i o`
  step, `s` stack, `v` variables, `e` evaluate, `q` stop), `<f5> <f9>
  <f10> <f11>`; lldb-dap and debugpy by default.
- MCP (off by default): `(mcp-enable!)` in init.scm, then an agent runs
  `imp --mcp` as its stdio MCP server (`claude mcp add imp -- imp --mcp`).
  Tools to read/edit/open/save buffers, the cursor, search, commands, ex
  commands, diagnostics and Scheme; agent changes show on the status line
  and in `:mcp-log`.
- The look (the polish pass the owner asked for): themes `one-dark`
  (default), `gruvbox-dark`, `everforest-dark`, `one-light` via `:theme` / `SPC t T`;
  `describe-face` (`SPC h F`) and `list-faces` in theme.scm, on the
  `face-names`, `face-spec` and `faces-at` primitives; a status
  line with a colored mode badge, file, modified dot, diagnostics counts,
  major mode, position and percent; which-key and menus under a titled
  rule with colored keys; LSP completion and hover in a bordered box at
  the cursor.
- The mouse: click to move (focusing the window), drag to select, wheel to
  scroll; `:set nomouse` turns it off (shift-drag still selects in most
  terminals while imp captures the mouse).
- The second polish pass (after Phase 6, asked for by the owner):
  - `<tab>` on the `:` line completes arguments too: files for `:e`, `:w`,
    `:sp` and the like, buffers for `:b`, options for `:set`, themes,
    help topics. It extends to what the candidates share, lists them in
    the popup, and further `<tab>`/`<s-tab>` step through them. Packages
    add more with `define-ex-completion!`.
  - M-x shows each command's keys (normal mode's and the leader's).
  - `K` without a language server gives Scheme help in Scheme files and
    says what's missing elsewhere.
  - `imp DIR` opens the file browser; Steel no longer prints over the
    screen when `~/.local/share` is missing.
  - `h`, `l`, `w`, `f` and the other horizontal motions open a closed fold,
    as Vim's default 'foldopen' does.

### Verified

- `cargo test`: 365 tests, plus the feature-gated ones (`tools/check.sh`
  runs them all). Clippy and fmt are clean. `nix build` (which runs the
  tests in its sandbox, git included) and `nix build .#gui` work.
- The release binary in a pty: splits with borders, patched redraws through
  scrolling, which-key on its timer, and a daemon with a direct client and a
  bridged one sharing a buffer, then `:kill-server`.
- Startup ~0.3 s in release (Steel's prelude dominates, as before).
- The release binary was driven through a pty (`pyte` screen): visual
  highlighting, search, `ci(`, `:%s`, `O` with autoindent, `:w`.
- `examples/bench.rs` on 100k lines: most commands ~0.1-0.3 ms per key
  including the frame; search ~3 ms; `ci(` ~8 ms.

## 4. Working on it

```sh
nix develop            # sets IMP_RUNTIME=$PWD/runtime
cargo test             # all behavior tests
cargo run -- FILE
cargo clippy --all-targets && cargo fmt --check
```

Conventions:
- **Test Vim behavior by feeding keys** (`tests/vim.rs`: `type_keys(&mut s,
  "dw.")`) and asserting text/cursor. Every new Vim feature gets tests in this
  style; compare against real Vim/Neovim behavior, since Vim users leave the
  moment their habits break.
- **New behavior goes in Scheme.** Add a Rust primitive to `api.rs` only when
  Scheme genuinely can't do it or it is too slow. Keep primitives small and
  general.
- Comments explain *why*, as in the existing code. Match the existing style.
- To exercise the real TUI, drive the release binary through a pty (Python
  `pty.fork()`, set `TIOCSWINSZ`, write keys, read output; `pyte` renders
  the screen: `nix-shell -p 'python3.withPackages(p:[p.pyte])'`). Set `HOME`
  to a temp dir so no user config loads.
- Test helper gotcha: `type_keys` reads `<` followed by a lowercase letter as
  a key name (`<esc>`), so send a literal `<` with `s.keys(&["<", "j"])`.
- Measure with `cargo run --release -p imp-server --example bench` before
  moving anything to Rust.
- `tools/check.sh` runs tests, clippy and fmt and fails if any fail; gate
  every commit on it. `tools/parens.py FILE.scm` finds unbalanced brackets
  (Steel's parse errors don't say where). `tools/drive.py` drives the real
  binary in a pty (see its docstring); `tools/shot.py` does the same and
  saves the screen as a PNG, colors and all, for checking how things look.
  Tests clear the theme's `normal` background (tests/common) so rows hold
  only what was drawn; tests/theme.rs covers the theme.
- Git: all six phases are on `main` (pushed to origin); the phase branches
  are gone. Ask the owner how to branch new work.
- Releases: GPL-3.0-or-later (`LICENSE`). The version is in `Cargo.toml`
  (workspace) and `flake.nix`; `imp --version` prints it. Pushing a `v*` tag
  runs `.github/workflows/release.yml`: a GitHub release (a prerelease for
  tags with a `-`, like `v0.1.0-alpha.1`) with binaries for x86_64 and
  aarch64 Linux and Apple-silicon macOS. `ci.yml` runs `tools/check.sh` and
  `nix build` on pushes to main and on pull requests.
- Building: the `Makefile` has every build, install and test target (`make`
  lists them). It uses plain cargo, so users need no Nix: `make install`
  puts imp in `~/.local/bin`. With Nix installed it runs cargo inside
  `nix develop`, as `tools/check.sh` does; the `nix-*` targets build the flake.
  The owner wants installs to work for people without Nix: keep the README
  leading with the binaries and `make install`.
- Current work and the detailed next steps are at the end of the latest
  `docs/design/phase-N.md` ("Progress").

### Steel gotchas found so far

- Missing builtins: `char-alphabetic?`, `char-numeric?`, `string-split`,
  `string-trim`, `char->string`. (Use `char-word?` from Rust, or
  `char->integer` ranges; `string` / `list->string` exist.)
- Present: `char-whitespace?`, `starts-with?`, `ends-with?`, `string-ref`,
  `substring`, `string->number`, named `let`, `case`, `syntax-rules`.
- Hash maps are **immutable**: `(hash-insert h k v)` returns a new map, so keep
  them in a top-level variable and `set!` it (see `*keymaps*`).
- A top-level variable must be defined before any function that references it
  is compiled, or you get `FreeIdentifier`. Put state at the top of the file.
- Code that *runs* at load time (a top-level `(define-key! ...)` call) must
  come after the definitions it calls; function bodies may refer forward.
- A `cond` clause with only a test returns void, not the test's value. Use
  `[(test) => (lambda (x) x)]`.
- Local names shadow builtins silently: a `let` binding called `range` broke
  a later `(range a b)` call in the same scope.
- No `raise`: re-raise a caught error with `(raise-error e)`. Catch with
  `(with-handler (lambda (e) ...) expr)`; `(error-object-message e)` has a
  leading space (see `error-message` in vim.scm).
- **Redefinition (the big one).** Re-`define`-ing an existing global makes
  a *new* binding that code compiled earlier never sees; `set!` changes the
  binding everyone uses. And within one compilation unit (one `run`, one
  file), a call to a function never `set!` in that unit is compiled as a
  direct call later `set!`s can't reach. Hence the markers and the
  `define`→`set!` rewrite described in "How it works". A function passed
  *as a value* at load time (`(word-motion next-word-start ...)`) is still
  captured; call by name inside a lambda where redefinition matters.
- A runtime file can't call a function first defined in a *later* runtime
  file (each file is its own unit), and `eval` of a form that references a
  global not yet defined fails; user code gets placeholders for those.
- `define-syntax` inside `(begin ...)` isn't visible to the later forms in
  it; macros are evaluated first.
- Defining a name the prelude already has (`take`, `log`) fails once it is
  `set!` ("cannot mutate module-required identifier"). Check new runtime
  names against the prelude; `crates/imp-server/examples/` is the place for
  such scratch tools.
- `void` is a value, not a function: `(void)` is an error.
- Symbols from Rust (JSON `null` is `'null`) aren't `eq?` to quoted ones;
  compare with `equal?`. `trim` and `char-digit?` are prelude names.
- Rust primitives returning `Result<_, String>` raise errors whose message is
  the Debug-quoted string; prefer a primitive that returns the error (like
  `pattern-error`) when Scheme needs to show it.
- Present and useful: `filter sort string-join split-whitespace
  string-contains? string-upcase number->string` (with radix),
  `string->number` (with radix), `eval`, `read`, `open-input-string`, `range`,
  `list-ref`, `last`, `hash-keys->list`.
- `Engine::new()` loads Steel's prelude: ~0.3s per server with dependencies
  optimized (the dev profile does this), so the suite runs in ~25s.

## 5. Known limitations and debt

Fix these when the roadmap item touching them comes up, not all at once.

1. **One server per thread.** Editor state is a `thread_local`, because Steel's
   `register_fn` takes plain functions. Tests must not run two servers at
   once on one thread (one after another is fine).
2. **Daemon clients share one cursor and layout**, like tmux sessions; each
   only has its own size. Scroll can differ per client size.
3. **Diagnostics don't move with edits** until the server republishes them
   (highlight ranges and signs are fixed offsets and lines).
4. **Undo** is whole-text snapshots; no undo tree. Marks aren't restored by
   undo (they are clamped into the text).
5. **Dot-repeat of inserts** replays the typed keys.
6. **No `:map`/`:noremap`**; bind keys with `define-key!` in Scheme.
7. **Search** converts the rope to a string per search (~3 ms on 100k lines).
8. **Which-key** shows for the leader and Emacs prefixes, not Vim's `g`/`z`.
9. **after-change** runs once per key, without the changed range; LSP sync
   (4.2) will need ranges.
10. **Package loading blocks** while `git clone` runs at startup.
11. **The REPL** has no input history.
12. **Block visual mode** uses char columns (a tab counts as one), unlike the
    renderer, which now measures display width.
13. **File times are whole seconds** for autosave comparisons.
14. **Folds are manual only** (no 'foldmethod' syntax/indent/expr).
15. **Org** covers outlines, TODOs, checkboxes, links, tables, agenda and
    capture. It lacks timestamps with repeaters, priorities, properties,
    export and babel, and typing in a table doesn't keep it aligned.
16. **Terminals** resize only for the current window, and don't pass mouse
    events or bracketed paste to the program.
17. **The file browser** can't swap two names in one save (a line that
    reads as an entry did is that entry).

## 6. Roadmap

Ordered by what makes imp livable for a Vim user first, then what makes it
Emacs-like, then the long-term architecture. Each phase should end with tests
and a pty-driven check of the real binary.

### Phase 1: daily-driver Vim (done)

All of 1.1–1.10 is built; see §3 "What works" and `docs/design/phase-1.md`.

1.1 **Text objects**: `iw aw iW aW`, `i" a" i' a' i( a( ib i[ i{ iB i< it`,
    `ip ap`. Add a text-object table in `vim.scm` (a text object returns
    `(start end linewise?)` directly, unlike motions) and accept them in
    operator-pending mode and visual mode. Later: tree-sitter-backed objects
    (`if af` function, `ia aa` argument, `ic ac` class), see Phase 4.
1.2 **Visual mode**: `v`, `V`, `C-v` (block can come later), `o` to swap ends,
    operators on the selection, `gv`. Needs: a selection in editor state, and
    the frame protocol must be able to show it (see 1.6 / Phase 3 styling).
1.3 **Search**: `/` `?` `n` `N` `*` `#`, search as a motion (`d/foo<ret>`),
    `:s/pat/rep/[g]` and `:%s`. Decide on a regex engine (the `regex` crate via
    a Rust primitive is the obvious choice).
1.4 **More motions**: `f F t T ; ,`, `%`, `{ }`, `H M L`, `C-d C-u C-f C-b`,
    `W B E`, `ge`, `gj gk`.
1.5 **More commands**: `r`, `R`, `J`, `~`, `>>` `<<` (and `>`/`<` operators),
    `gu gU` operators, `C-a C-x`, counts on insert and paste, `<del>`, `<home>`,
    `<end>`.
1.6 **Registers**: named `"a`–`"z`, append `"A`, yank register `"0`, numbered
    delete registers, black hole `"_`, system clipboard `"+`/`"*` (needs a Rust
    primitive or shelling out to `wl-copy`/`pbcopy`).
1.7 **Macros**: `q{reg}` / `@{reg}` / `@@`. Record keys in Scheme.
1.8 **Undo polish**: restore cursor to the change, `U`, undo tree later.
1.9 **Marks and jumps**: `m{a-z}`, `` ` `` and `'`, jump list `C-o C-i`.
1.10 **Ex command line polish**: history, `:e FILE`, ranges (`:1,5d`), and an
     `:eval (scheme...)` command to run Scheme live from inside the editor.
     That last one is very important to the Emacs feel; check what Steel
     offers for `eval`.

### Phase 2: the Emacs half (live, self-documenting, extensible) (done)

All of 2.1–2.8 is built; see §3 and `docs/design/phase-2.md`.

2.1 **Live REPL / eval-in-editor**: evaluate a region or the form before point,
    redefine functions without restarting. This is the defining Emacs
    capability; it should arrive early.
2.2 **Self-documentation**: `describe-key`, `describe-function` (docstrings),
    jump to a function's Scheme source.
2.3 **Hooks and advice**: hook lists (`after-save-hook`, `mode-hooks`,
    `post-command-hook`) and before/after/around advice on any Scheme function.
2.4 **Leader key + which-key**: space leader by default (Spacemacs/Doom
    style), with a popup listing available continuations.
2.5 **Optional Emacs ("holy") bindings**: a supported alternative state set,
    not an afterthought. People who want the Lisp flexibility often have Emacs
    habits.
2.6 **Major and minor modes**: per-buffer modes, mode-local keymaps, a mode
    chosen by file type.
2.7 **Package system ("tomes")**: a way to load third-party Scheme packages
    from a directory and declare them in `init.scm` (think `use-package`).
2.8 **Completion framework**: a minibuffer with fuzzy completion
    (vertico/orderless-style). One of the "killer packages" a new editor
    needs to attract users.

### Phase 3: editor infrastructure (done)

All of 3.1–3.8 is built; see §3 and `docs/design/phase-3.md`.

3.1 **Multiple buffers**: buffer list, `:e`, `:bn/:bp`, `:ls`.
3.2 **Windows**: splits (`C-w s/v/h/j/k/l`), layout owned by the server.
3.3 **Styled frames** (styles done in Phase 1; diffs remain): extend the protocol from rows of strings to cells with
    styles (fg/bg/bold/underline), then send diffs instead of full frames.
    Needed for highlighting, visual mode and search highlights.
3.4 **Unicode display width** (`unicode-width` crate), configurable tab width.
3.5 **The socket transport**: `imp --daemon` (server) and `imp FILE`
    (client) over a Unix socket; buffers survive closing the terminal.
    Several clients can attach. Keep the in-process mode for tests. The
    channels in `crates/imp/src/main.rs` are where the socket goes; the
    `ClientMsg`/`ServerMsg` types need a serialization (e.g. `serde` +
    MessagePack or JSON lines).
3.6 **Remote editing**: server on another machine, client local (falls out of
    3.5 plus ssh).
3.7 **Background-work model**: LSP, file watching and slow parsing run on
    worker threads and post messages to the main loop. The single thread that
    owns the Steel VM is what keeps "redefine anything live" safe; don't
    share editor state across threads.
3.8 **File handling**: detect external changes, line endings, encodings,
    backups/autosave.

### Phase 4: IDE features through protocols (done; see docs/design/phase-4.md)

4.1 **Tree-sitter**: syntax highlighting (needs 3.3), structural text objects
    (`af`, `if`, `aa`...), indentation, folding.
4.2 **LSP client**: diagnostics, go to definition, hover, completion, rename,
    code actions. The protocol plumbing lives in Rust; the UI and keybindings
    in Scheme.
4.3 **DAP client**: debugging.
4.4 **MCP**: expose buffers and commands to AI agents over MCP, so an agent has
    the same access as a human. This was part of the original "born in 2026"
    vision; Emacs's "everything is a command" model suits it well.

### Phase 5: long-term architecture (done as prototypes; see docs/design/phase-5.md)

5.1 **WASM plugins** (wasmtime component model): sandboxed, fast plugins
    written in any language, for heavy work (formatters, indexers) or code
    you don't want running with full trust. Scheme stays the main extension
    language; WASM is the second tier.
5.2 **GPU GUI client**: wgpu with WGSL shaders, `cosmic-text` for text. It is
    just another client of the same protocol.
5.3 **CRDT buffers**: collaborative editing and safe concurrent edits from
    agents. Proceed carefully; Xi-editor was abandoned partly over CRDT
    complexity. Zed shows it can work.
5.4 **Optional typed/declarative config layer** (e.g. Nickel or KDL) for
    reproducible configs alongside the live Scheme one. Low priority.

### Phase 6: the ecosystem (what decides whether imp succeeds) (done; see docs/design/phase-6.md)

People use Emacs for its packages, not Elisp. Targets, roughly in order:
6.1 a Magit-equivalent git interface; 6.2 Org-mode compatibility (the most
common "why I can't leave Emacs"); 6.3 a file browser (dired/oil-style);
6.4 project management (projectile/project.el-style); 6.5 terminal/shell
buffers.

## 7. Risks to keep in mind

- **Scheme performance.** If keystroke paths (keymap dispatch, redisplay
  hooks, completion) are too slow in Steel, the temptation is to move code
  into Rust, which erodes the 80% rule. Measure before moving anything; prefer
  faster primitives over moving behavior.
- **Concurrency vs. live redefinition.** Keep one thread owning the VM and all
  editor state; everything else talks to it with messages.
- **Steel maturity.** It is young. Expect missing builtins and rough error
  messages; pin the version and upgrade deliberately.
- **Scope.** A personal daily driver is very achievable; an Emacs competitor
  is a multi-year community effort. Phases 1–2 are what make it worth using.

## 8. References

- Helix and its Steel plugin branch: Rust editor embedding Steel (closest
  technical prior art for the Rust/Scheme boundary). Note Helix uses
  Kakoune's select-then-act grammar, not Vim's.
- Lem: Common Lisp editor with a `vi-mode`; closest in spirit.
- Evil (Emacs): the edge cases of Vim emulation are documented in its source.
- Neovim: the behavior to match, and its UI protocol (grid-based) as a model
  for the frame protocol.
- Xi-editor retrospective: lessons on CRDTs and RPC plugins.
- Zed: Rust, GPU rendering, WASM extensions, CRDTs done well.
