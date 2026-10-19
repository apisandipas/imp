# imp

An editor as flexible as Emacs, with Vim editing by default. A small Rust
core runs the buffers, rendering and parsing; the editor itself (every key,
command, mode and package) is Scheme ([Steel](https://github.com/mattwparas/steel))
that you can read, redefine and extend while it runs.

> **Alpha.** imp is young. It is usable day to day for Vim-style editing, but
> expect rough edges, missing pieces and changes to the Scheme API. Bug
> reports are welcome.

## Install

With [Nix](https://nixos.org):

```sh
nix run github:apisandipas/imp -- FILE        # try it
nix profile install github:apisandipas/imp   # install it
```

With Rust (a recent stable toolchain and a C compiler, for the tree-sitter
grammars):

```sh
cargo install --git https://github.com/apisandipas/imp imp-editor
```

Prebuilt binaries for Linux (x86_64, aarch64) and macOS (Apple silicon) are
attached to each [release](https://github.com/apisandipas/imp/releases). The
binary is self-contained: the Scheme runtime is built into it. On Linux the
window needs the usual desktop libraries (Vulkan or OpenGL, and Wayland or
X11), which any desktop already has. For a server, `nix build .#tui` or
`cargo install ... --no-default-features` builds a terminal-only imp.

Linux and macOS only. The clipboard uses `wl-copy`, `xclip`, `xsel` or
`pbcopy`; project search uses `rg`; language servers and debug adapters are
whatever you have installed.

## Using it

`imp` opens in a window. Over SSH, on a console, or anywhere without a
display it runs in the terminal instead, and `imp --tui` always does (for
`$EDITOR`, say: `export EDITOR="imp --tui"`).

With no file it shows a start screen of recent files and projects; `imp
FILE...` opens files, `imp DIR` a file browser. In the window, `C-=` and
`C--` zoom, `C-0` resets, and `--font FAMILY`, `--font-size PX` and
`--scale F` (or `$IMP_GUI_SCALE`, for HiDPI screens) set the text.

- **Vim.** Motions, operators, text objects, counts, `.`, registers, macros,
  marks, visual modes, search and `:s`, `:g`, folds, splits and buffers,
  matched against real Vim's behavior.
- **Space leader.** `SPC` shows what follows it: `f` files, `b` buffers, `w`
  windows, `p` projects, `s` search, `g` git, `c` code, `o` org and
  terminals, `h` help, `t` toggles. `M-x` runs any command by name.
- **Emacs keys.** `C-z` switches to an Emacs state (`C-x C-f`, `C-x C-s` and
  friends) and back.
- **IDE features.** Tree-sitter highlighting and text objects (Rust, Scheme,
  TypeScript/JavaScript, Nix, Markdown); language servers (diagnostics,
  `K`, `gd`, `gr`, rename, code actions, formatting, completion), set up for
  rust-analyzer, typescript-language-server, nil, marksman and pyright when
  they're on your `PATH`, and more with `define-language-server!`; debugging
  over DAP.
- **Packages that come with it.** A Magit-style git interface (`SPC g g`),
  Org outlines, TODOs, tables, agenda and capture, an editable file browser
  (`:Ex`), projects with search into a quickfix list, and terminals
  (`:terminal`).
- **Help.** `:help`, `SPC h k` (describe key), `SPC h f` (describe
  function), `SPC h o` (describe option).

## Configuration

`~/.config/imp/init.scm` (or `$XDG_CONFIG_HOME/imp/init.scm`) loads after the
runtime and can change anything in it. `c` on the start screen opens it.
[`examples/init.scm`](examples/init.scm) is a commented starting point:

```scheme
(set-option! 'relativenumber #t)
(load-theme! 'gruvbox-dark)                  ; one-dark, gruvbox-dark, one-light

(define-key! 'normal "C-s" 'save-buffer)

;; A command of your own, on the leader and in M-x.
(define-command! 'insert-date
  (lambda (count)
    (begin-change!)
    (buffer-insert! (cursor) (without-final-newline (cadr (run-shell "date +%F" ""))))))
(define-leader! "id" 'insert-date "insert date")
```

An error in `init.scm` shows on the status line; the editor still starts.
Edit it and `SPC e b` (evaluate buffer) to apply changes without a restart.
Packages load from `~/.config/imp/packages`, or from git with
`use-package!`.

## Daemon

```sh
imp --daemon                    # an editor with no terminal, on a socket
imp --connect FILE              # attach a terminal to it
imp --connect --via 'ssh host imp --bridge'
```

## Developing

`make` lists every build and test target (`make run`, `make dev`, `make
check`, `make install` ...). Underneath:

```sh
nix develop          # or any recent stable Rust toolchain
cargo run -- FILE
tools/check.sh       # tests, clippy and fmt, as CI runs them
```

Inside `nix develop`, `IMP_RUNTIME` points at `runtime/`, so edits to the
Scheme files take effect when imp restarts, with no rebuild.

```
crates/
  imp-core/    the text buffer and the client/server messages
  imp-server/  the event loop, Steel embedding, the Rust functions Scheme calls
  imp/         the imp binary (package imp-editor) and the terminal client
  imp-gui/     the window client: winit, wgpu and glyphon
runtime/       the editor, in Scheme
```

[`docs/HANDOFF.md`](docs/HANDOFF.md) has the design decisions, the
architecture, the Scheme API, known limitations and the roadmap;
`docs/design/` has notes per phase.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
