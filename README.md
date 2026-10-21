# imp

An editor as flexible as Emacs, with Vim editing by default. A small Rust
core runs the buffers, rendering and parsing; the editor itself (every key,
command, mode and package) is Scheme ([Steel](https://github.com/mattwparas/steel))
that you can read, redefine and extend while it runs.

> **Alpha.** imp is young. It is usable day to day for Vim-style editing, but
> expect rough edges, missing pieces and changes to the Scheme API. Bug
> reports are welcome.

## Install

**Download a binary.** Each
[release](https://github.com/apisandipas/imp/releases) has one for Linux
(x86_64, aarch64) and macOS (Apple silicon). It is a single self-contained
file (the Scheme runtime is built in); put it anywhere on your `PATH`:

```sh
tar xzf imp-*.tar.gz
install -m 755 imp-*/imp ~/.local/bin/    # or: sudo install -m 755 imp-*/imp /usr/local/bin/
```

On Linux, the archive also has a desktop file and icon for app launchers:

```sh
sed "s|^Exec=imp |Exec=$HOME/.local/bin/imp |" imp-*/imp.desktop > ~/.local/share/applications/imp.desktop
install -Dm644 imp-*/imp.svg ~/.local/share/icons/hicolor/scalable/apps/imp.svg
```

On macOS, a downloaded binary is quarantined; clear it with
`xattr -d com.apple.quarantine ~/.local/bin/imp`.

**Build from source.** You need [Rust](https://rustup.rs) (recent stable) and a
C compiler (`build-essential` on Debian/Ubuntu, Xcode command line tools on
macOS). No other libraries are needed to build.

```sh
git clone https://github.com/apisandipas/imp && cd imp
make install       # builds and installs ~/.local/bin/imp (have it on PATH),
                   # plus a desktop file and icon under ~/.local/share
make install-tui   # or a terminal-only imp, no window code
make upgrade       # later: git pull, rebuild, reinstall
make uninstall
```

On NixOS, install with `make nix-install` (`nix profile install .#default`)
instead: a cargo-built imp can't find the graphics libraries outside
`nix develop`, so it can't open its window from a launcher.

For every user, build as yourself and copy as root:
`make build && sudo install -m 755 target/release/imp /usr/local/bin/`.

Run `make` alone to list every target. Without make,
`cargo install --git https://github.com/apisandipas/imp imp-editor` installs
into `~/.cargo/bin` (add `--no-default-features` for terminal-only).

**With Nix**, `nix profile install github:apisandipas/imp` (or
`make nix-install` from a checkout). On NixOS use this rather than the binary
or `make install`, since those look for the window libraries in the usual
system places.

On Linux the window uses the desktop libraries every desktop already has
(Vulkan or OpenGL, and Wayland or X11). Without a display imp runs in the
terminal, so the same binary works on a server.

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
`--scale F` (or `$IMP_GUI_SCALE`, for HiDPI screens) set the text. In
`init.scm` the options `font`, `font-size`, `window-padding` (pixels) and
`background-opacity` (0 to 1) set the window; in a terminal,
`terminal-background` off lets the terminal's own background show.

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
  rust-analyzer, TypeScript 7's tsgo (or typescript-language-server), nil,
  marksman and pyright when they're on your `PATH`, and more with `define-language-server!`; debugging
  over DAP.
- **Completion.** In insert state `C-n`/`C-p` complete what's before
  the cursor: a file path, or the language server's suggestions, imp's
  own names (with their docs) in Scheme and words from your buffers
  (nearest first), merged and ranked. In code the menu opens by itself
  as you type; `C-x C-f` completes file names. Sources per major mode
  (`set-completion-sources!`), key presets (`completion-keys`: `vim`,
  `tab`, `enter`), the menu's columns, and `define-completion-source!`
  for your own. The `:` line gets the same menu as you type (commands,
  files, buffers, options with their docs), and `/` the buffer's words.
- **Snippets.** Language servers' snippets expand with their tab stops:
  `<tab>`/`<s-tab>` move between them, typing replaces a placeholder,
  mirrors follow, choices come in a menu. Your own with
  `(define-snippet! 'rust-mode "fn" "fn ${1:name}() {\n\t$0\n}")`, or
  VS Code snippet files with `load-snippets!`.
- **Files.** `SPC f D`, `SPC f R` and `SPC f C` (or `M-x delete-file`,
  `rename-file`, `copy-file`) act on the current buffer's file unless you
  name another; deleting asks first, and the buffer follows a rename.
- **Packages that come with it.** A Magit-style git interface (`SPC g g`),
  Org outlines, TODOs, tables, agenda and capture (templates, a capture
  window, `C-c C-c` to file, refiling), an editable file browser
  (`:Ex`, with permissions, size and time beside each name; `(` hides
  them), projects with search into a quickfix list, and terminals
  (`:terminal`). Search results open along the bottom and git down the
  right, closing with `q`; `define-popup-rule!` changes where.
- **Claude Code.** `M-a` (or `SPC a a`) opens Claude Code for the current
  project in a window down the right, and hides it again from inside;
  hidden, it keeps running. `SPC a s` sends the selection (or the line),
  `SPC a b` the buffer and `SPC a f` a reference to the file into its
  prompt, labelled with the file and lines, for you to say what to do.
- **Help.** `:help`, `SPC h k` (describe key), `SPC h f` (describe
  function), `SPC h o` (describe option), `SPC h F` (the faces under the
  cursor, to change with `set-face!`), `M-x list-faces` (every face, drawn
  in itself). M-x shows each command's keys and what it does. Functions
  carry Emacs-style docstrings, which help shows; yours in `init.scm`
  can too.

## Configuration

`~/.config/imp/init.scm` (or `$XDG_CONFIG_HOME/imp/init.scm`) loads after the
runtime and can change anything in it. `c` on the start screen opens it.
[`examples/init.scm`](examples/init.scm) is a commented starting point:

```scheme
(set-option! 'relativenumber #t)
(load-theme! 'gruvbox-dark)                  ; one-dark, gruvbox-dark, everforest-dark, one-light

(define-key! 'normal "C-s" 'save-buffer)

;; A command of your own, on the leader and in M-x.
(define-command! 'insert-date
  (lambda (count)
    "Insert today's date at the cursor."    ; what M-x and SPC h f show
    (begin-change!)
    (buffer-insert! (cursor) (without-final-newline (cadr (run-shell "date +%F" ""))))))
(define-leader! "id" 'insert-date "insert date")
```

An error in `init.scm` shows on the status line; the editor still starts.
Edit it and `SPC e b` (evaluate buffer) to apply changes without a restart.
Packages load from `~/.config/imp/packages`, or from git with
`use-package!`. A few come with imp, off until you ask for them:

```scheme
(use-package! 'olivetti                       ; a centred column of text
  'config (lambda () (set-option! 'olivetti-modes '(org-mode markdown-mode))))
(use-package! 'posframe)                      ; M-x and friends in a centred box
(use-package! 'org-babel)                     ; C-c C-c runs Org source blocks
(use-package! 'move-lines)                    ; J and K move lines selected with V
(use-package! 'nerd-icons)                    ; icons in the status line and menus
```

`:packages` lists what's loaded and what else comes with imp.

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
cargo run -- FILE    # with Nix, inside `nix develop` for the pinned toolchain
tools/check.sh       # tests, clippy and fmt, as CI runs them
```

With `IMP_RUNTIME=$PWD/runtime` set (`nix develop` sets it), imp loads the
Scheme files from `runtime/`, so edits to them take effect when imp restarts,
with no rebuild.

```
crates/
  imp-core/    the text buffer and the client/server messages
  imp-server/  the event loop, Steel embedding, the Rust functions Scheme calls
  imp/         the imp binary (package imp-editor) and the terminal client
  imp-gui/     the window client: winit, wgpu and glyphon
runtime/       the editor, in Scheme
packages/      opt-in packages that come with imp (use-package!)
```

[`docs/HANDOFF.md`](docs/HANDOFF.md) has the design decisions, the
architecture, the Scheme API, known limitations and the roadmap;
`docs/design/` has notes per phase.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
