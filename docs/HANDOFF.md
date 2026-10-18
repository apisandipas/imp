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
| UI | **Terminal first**, GUI later | Much cheaper to start; GUI becomes another client. |
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

## 3. Current state (commit `85edadd`, plus this document)

### Layout

```
Cargo.toml                 workspace
flake.nix                  dev shell + package (NOT YET VERIFIED, see §5)
crates/
  imp-core/                Buffer (ropey + snapshot undo), protocol types
    src/buffer.rs
    src/protocol.rs        ClientMsg, ServerMsg, Frame, CursorShape
  imp-server/              the editor
    src/lib.rs             Server, run(), runtime loading, init.scm loading
    src/editor.rs          Editor state in a thread-local
    src/api.rs             THE Rust->Scheme boundary (~25 primitives)
    src/render.rs          Editor -> Frame (scrolling, tabs, status line)
    tests/vim.rs           19 key-driven Vim behavior tests
    tests/config.rs        3 init.scm tests
  imp/                     terminal client (package imp-editor, bin imp)
    src/main.rs            crossterm; runs the server on a thread
runtime/
  core.scm                 keymaps, buffer helpers, default entry points
  vim.scm                  modes, motions, operators, dot-repeat, :commands
```

### How it works

- The client spawns `imp_server::run` on a thread, connected by two `mpsc`
  channels. Client sends `ClientMsg::Key("j")` / `Resize`; server replies with
  a full `Frame` (rows of text + cursor position + cursor shape) or `Quit`.
- For every key the server calls the Scheme function `(imp-handle-key key)`.
  `vim.scm` defines it. Rust has no idea what keys mean.
- Key names: `"j"`, `"<esc>"`, `"<ret>"`, `"<bs>"`, `"<tab>"`, `"<del>"`,
  `"<left>"`/`"<right>"`/`"<up>"`/`"<down>"`, `"C-r"`.
- Runtime `.scm` files are embedded with `include_str!`. If `IMP_RUNTIME` is
  set (the dev shell sets it to `$PWD/runtime`), they load from disk instead,
  so Scheme edits need only a restart.
- Load order: `core.scm`, `vim.scm`, user `init.scm`, then `(imp-init)`. An
  error in `init.scm` goes to the status line; the editor still starts.
- Scheme errors at runtime are caught and shown as `error: ...` on the status
  line.

### The Scheme API (`crates/imp-server/src/api.rs`)

Reading: `buffer-length`, `buffer-char-at`, `buffer-substring`,
`buffer-line-count`, `buffer-line-length`, `line-col->offset`, `offset->line`,
`offset->col`, `buffer-modified?`, `buffer-name`, `char-word?`.
Changing: `buffer-insert!`, `buffer-delete!` (returns removed text),
`undo-boundary!`, `undo!`, `redo!`, `save!`.
Cursor: `cursor`, `set-cursor!` (both char offsets).
UI: `set-status!`, `set-mode-name!`, `set-cursor-shape!` (`"bar"`/`"block"`),
`quit!`.

All positions are **char offsets** into the whole buffer. Integers are `isize`
on the Rust side because Steel ints are signed; negatives clamp to 0.

### Extension points in Scheme

- `(define-key! mode key command)`: `core.scm`. Normal-mode commands take
  `(count)`.
- `(define-motion! key type proc)`: `vim.scm`. `type` is `'exclusive`,
  `'inclusive` or `'linewise`; `proc` is `(lambda (from count) target-offset)`.
  New motions work with every operator, counts and `.` automatically.
- `(define-operator! key proc)`: `proc` is `(lambda (start end linewise?) ...)`.
- `(define-ex! name thunk)`: `:` commands.

### What works

Normal: `h j k l` and arrows, `w b e 0 ^ $ gg G`, counts (`3w`, `2d3w`
multiplies), operators `d c y` with any motion and doubled (`dd cc yy`),
`x X D C s`, `p P`, `u`, `C-r`, `.`. `cw` acts like `ce` as in Vim. `dw` on the
last word of a line keeps the newline. `dd` on the last line keeps the file's
final newline.
Insert: `i a I A o O`, typing, `<ret> <tab> <bs> <left> <right>`, `<esc>`.
Command line: `:w :q :q! :wq :x :N`.

### Verified

- `cargo test`: 25 tests pass (3 buffer, 19 Vim, 3 config).
- `cargo clippy --all-targets` clean, `cargo fmt --check` clean.
- The release binary was driven through a pty: started in 0.33s, `dw`, `j`,
  `dd`, `onew<esc>`, `:wq` produced exactly the expected file.

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
  `pty.fork()`, set `TIOCSWINSZ`, write keys, read output). Set `HOME` to a temp
  dir so no user config loads.

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
- `Engine::new()` loads Steel's prelude: ~1s per server in debug builds (the
  test suite takes ~20s because each test creates one), ~0.3s in release.

## 5. Known limitations and debt

Fix these when the roadmap item touching them comes up, not all at once.

1. **Flake unverified.** nixpkgs could not be fetched in the session that wrote
   it. Run `nix develop` and `nix build` once; `Cargo.lock` must be committed
   (it is).
2. **One server per thread.** Editor state is a `thread_local`, because Steel's
   `register_fn` takes plain functions. Fine for one session; revisit for
   multiple buffers/clients (probably one `Editor` holding many buffers, still
   on one thread).
3. **Single buffer, single window.** No buffer list, no splits.
4. **Full-frame redraw** on every key, plain text only (no colors/styles), and
   char count is used as display width (wide CJK/emoji chars will misalign).
   Tabs render as 4 columns.
5. **Undo** is whole-text snapshots (cheap with ropes) but `undo_boundary`
   compares ropes for equality, which is O(n). Cursor isn't restored to the
   change position on undo. No undo tree.
6. **Counts are ignored** for inserts (`3ihi<esc>`) and paste (`3p`).
7. **Dot-repeat of inserts** replays the typed keys inside the recorded change
   (the change itself is a closure). Good enough; revisit if insert-mode
   completion makes typed keys diverge from inserted text.
8. **Single unnamed register.** No `"a`–`"z`, no system clipboard.
9. **No `<del>`/`<home>`/`<end>`/`<pageup>` handling** in Scheme yet (client
   only sends `<del>`).
10. **`gg`/`G` with an operator** are treated as linewise but untested
    (`dgg`, `dG`).
11. **Client/server is in-process.** Channels only; no socket yet.

## 6. Roadmap

Ordered by what makes imp livable for a Vim user first, then what makes it
Emacs-like, then the long-term architecture. Each phase should end with tests
and a pty-driven check of the real binary.

### Phase 1: daily-driver Vim (next)

The owner was offered these as the next step; 1.1–1.3 recommended first.

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

### Phase 2: the Emacs half (live, self-documenting, extensible)

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

### Phase 3: editor infrastructure

3.1 **Multiple buffers**: buffer list, `:e`, `:bn/:bp`, `:ls`.
3.2 **Windows**: splits (`C-w s/v/h/j/k/l`), layout owned by the server.
3.3 **Styled frames**: extend the protocol from rows of strings to cells with
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

### Phase 4: IDE features through protocols

4.1 **Tree-sitter**: syntax highlighting (needs 3.3), structural text objects
    (`af`, `if`, `aa`...), indentation, folding.
4.2 **LSP client**: diagnostics, go to definition, hover, completion, rename,
    code actions. The protocol plumbing lives in Rust; the UI and keybindings
    in Scheme.
4.3 **DAP client**: debugging.
4.4 **MCP**: expose buffers and commands to AI agents over MCP, so an agent has
    the same access as a human. This was part of the original "born in 2026"
    vision; Emacs's "everything is a command" model suits it well.

### Phase 5: long-term architecture

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

### Phase 6: the ecosystem (what decides whether imp succeeds)

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
