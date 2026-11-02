---
type: Page
spec: "[[spec/nerd-icons]]"
frozen:
  docs/specs/nerd-icons.md: 5b1d62bdf17a
---
# Nerd icons

Nerd icons puts a small icon before each file, buffer and menu entry, picked by its type, and shows the git branch on the status line. It works as Emacs's nerd-icons does.

## Not yet in imp

- The branch on the status line isn't re-read after `git checkout` or `git switch`; open the buffer again to see the new one.
- Changing `nerd-icons-statusline` after the package has loaded does nothing.

## Turning it on

Nerd icons is an opt-in package. Load it in your `init.scm`:

```scheme
(use-package! 'nerd-icons)
```

It takes effect at once, in buffers already open too. There's no command to turn it off; remove the line and restart.

The icons are characters from a Nerd Font, so your font needs them. A "Nerd Font Mono" works best, because its icons are one column wide:

```scheme
(set-option! 'font "VictorMono Nerd Font Mono")
```

## Where the icons show

| Where | What you see |
|---|---|
| Status line | The buffer's icon before its name, and a branch icon with the git branch on the right |
| `M-x` and other pickers | A file's icon by its type in find-file, a buffer's in switch-buffer, a bolt before each command in `M-x`, and icons for symbols, options, projects and themes |
| Completion in insert state | The kind of each language server suggestion (function, variable, class...), file and folder icons when completing a path with `C-x C-f`, and icons for Scheme symbols and snippets |
| `:` command line menu | A file icon for paths, a bolt for commands |
| [File browser](ref-dired.md) and [file tree](ref-file-tree.md) | An icon before each name, lined up; an open folder in the tree gets an open-folder icon |

## How an icon is picked

A file's icon comes from its whole name first (`Makefile`, `Cargo.toml`, `README.md`), then its extension (`.rs`, `.py`, `.org`), else a plain file icon. A folder gets a folder icon.

A buffer with a file gets its file's icon. Other buffers get their mode's icon: a folder for dired, a terminal for terminals, git's logo for git buffers, a robot for Claude.

## Adding or changing an icon

Use `set-nerd-icon!` in your `init.scm`, with the icon's code point in hexadecimal. The Nerd Fonts cheat sheet lists them.

```scheme
(set-nerd-icon! 'extension "zig" "E6A9")   ; .zig files
(set-nerd-icon! 'name "justfile" "E779")   ; a whole file name
(set-nerd-icon! 'mode 'zig-mode "E6A9")    ; buffers in a major mode
```

The kinds are `'extension` (without the dot), `'name`, `'mode`, `'category` (a picker's, such as `'command`) and `'lsp-kind` (a completion kind number).

## Options

| Option | Default | What it does |
|---|---|---|
| `nerd-icons-statusline` | `#t` | Add the file icon and git branch to the status line. Set it before the package loads |
