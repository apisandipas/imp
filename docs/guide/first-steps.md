# Install and first steps

## Install

Each [release](https://github.com/apisandipas/imp/releases) has a binary for Linux (x86_64 and aarch64) and macOS (Apple silicon). It's a single file. Unpack it and put it on your `PATH`:

```sh
tar xzf imp-*.tar.gz
install -m 755 imp-*/imp ~/.local/bin/
```

On macOS, clear the download quarantine first: `xattr -d com.apple.quarantine ~/.local/bin/imp`.

To build from source you need [Rust](https://rustup.rs) and a C compiler:

```sh
git clone https://github.com/apisandipas/imp && cd imp
make install
```

With Nix, run `nix profile install github:apisandipas/imp`. On NixOS, use this rather than the binary.

A few things imp uses if you have them:

| Program | For |
|---|---|
| `wl-copy`, `xclip`, `xsel` or `pbcopy` | The system clipboard |
| `rg` (ripgrep) | Searching a project |
| Language servers, such as `rust-analyzer` | Code intelligence; see [LSP](ref-lsp.md) |
| `git` | The git interface; see [Git](ref-git.md) |

## Start it

| Command | What happens |
|---|---|
| `imp` | Opens a window with the start screen: recent files and projects |
| `imp notes.txt` | Opens a file |
| `imp src/` | Opens a file browser on a directory |
| `imp --tui` | Runs in the terminal instead of a window |

Without a display, over SSH for example, imp runs in the terminal by itself. To use imp for git commit messages and the like, set `export EDITOR="imp --tui"`.

In the window, `C-=` and `C--` zoom and `C-0` resets.

## Edit like Vim

imp starts in Vim's normal state. Motions, operators, text objects, counts, `.`, registers, macros, marks, visual mode, search and `:s` all work as in Vim. See [Vim](ref-vim.md) for the details.

| Key | What it does |
|---|---|
| `i` | Insert text; `<esc>` goes back to normal |
| `:w` | Save |
| `:q` | Close the window |
| `u` / `C-r` | Undo and redo |

Prefer Emacs keys? Press `C-z` to switch to Emacs state, and again to switch back. See [Emacs state](ref-emacs-state.md).

## The space menu

Press `SPC` in normal state and a menu shows what comes next. Each letter opens a group:

| Key | Group |
|---|---|
| `SPC f` | Files: `SPC f f` finds a file, `SPC f r` recent files, `SPC f s` saves |
| `SPC b` | Buffers: `SPC b b` switches, `SPC b d` closes |
| `SPC w` | Windows: `SPC w v` splits right, `SPC w s` splits below |
| `SPC p` | Projects: `SPC p p` switches, `SPC p f` finds a file in the project |
| `SPC s` | Search: `SPC s p` searches the project |
| `SPC g` | Git: `SPC g g` opens the git status |
| `SPC c` | Code: language server actions |
| `SPC o` | Org and terminals |
| `SPC h` | Help |
| `SPC t` | Toggles |

`SPC SPC` finds a file. You don't need to learn these by heart: the menu always shows them. When you pause after `g`, `z`, `[`, `]` or `C-w`, imp shows the keys that can follow those too. See [Leader and modes](ref-leader-and-modes.md).

## Run any command

`M-x` lists every command. Type part of a name to narrow the list. Each command shows its key, if it has one, and what it does.

## Get help

| Key | What it does |
|---|---|
| `SPC h k` | Press a key, and see what it runs |
| `SPC h f` | Look up a function and read its docs |
| `SPC h o` | Look up an option |
| `:help` | Open the help |

See [Live Scheme and help](ref-live-scheme-and-help.md).

## Next

Make imp yours: [Configuring init.scm](configuring.md).
