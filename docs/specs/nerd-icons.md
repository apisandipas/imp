---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/158
summary: "The nerd-icons package: Nerd Font icons before file and buffer names in the status line, the pickers, the completion menu, dired and the file tree, and the git branch on the status line."
anchors: [packages/nerd-icons/nerd-icons.scm, crates/imp-server/tests/nerd_icons.rs]
---
# Nerd icons

A bundled package, after Emacs's [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el), that puts a small icon before each file, buffer and menu entry, chosen by its type. The icons are characters in a Nerd Font's private-use area, so they show only in a font that has them, best a "Nerd Font Mono", whose icons are one cell wide. It is off until loaded ([[0011-non-essential-features-are-opt-in-packages]]), with `(use-package! 'nerd-icons)`.

## Behaviour

- Loading it turns it on everywhere at once, in buffers already open as well as new ones. It has no command to turn it off again.
- **Which icon.** A file's icon is looked up by its whole name first (`Makefile`, `Cargo.toml`, `README.md`...), then by its extension (`rs`, `scm`, `py`, `org`...), else a plain file icon. A name ending in `/` is a folder and gets a folder icon. A buffer with a file gets its file's icon; a buffer without one gets its major mode's (`dired-mode`, `term-mode`, `git-status-mode`...), a Claude session buffer a robot, and any other a plain file icon.
- **The status line.** With `nerd-icons-statusline` on (the default) when the package loads, the status line format gets `%{icon}` before the file name and `%{branch}` at the start of its right-hand side ([[spec/look]]), unless it has them already or lacks the place to put them (`%#status.file#%f`, `%=`). Each buffer's `%{icon}` is its icon, and its `%{branch}` is a branch icon and the current branch of the git repository holding its file, or nothing for a buffer without a file or outside a repository. Both are set when the package loads and again whenever a buffer's major mode is set or it is renamed.
- **The pickers.** In `completing-read` menus ([[spec/completion]]) each candidate has an icon before it: files by type and buffers as above in find-file and switch-buffer, and by the menu's category elsewhere: a bolt before each command in `M-x`, and icons for symbols, options, projects and themes. A menu of another category has no icons.
- **The completion menu.** In insert state's completion menu ([[spec/completion-at-point]]) a language server's candidate gets the icon of its completion item kind (function, variable, class, keyword... as VS Code's codicons; plain text when it gives none), a file path completed with `C-x C-f` its file or folder icon, a Scheme symbol the symbol icon, and a snippet the snippet icon. In the `:` command line's menu an entry with a `/` or `.` in it gets a file icon and any other the command bolt.
- **Dired and the file tree.** Each entry in a dired buffer ([[spec/dired]]) and in the file tree ([[spec/file-tree]]) has its icon before its name, lined up with the others, and an open folder in the tree an open-folder icon. Dired buffers already open redraw with icons when it loads.
- `set-nerd-icon!` adds or changes an icon: `(set-nerd-icon! 'extension "zig" "E6A9")` gives `.zig` files the Nerd Font character U+E6A9. The kinds are `'extension` (without the dot), `'name` (a whole file name), `'mode` (a major mode), `'category` (a picker's category, such as `'command`) and `'lsp-kind` (a completion item kind number). The change shows the next time an icon is drawn.

## Keys and options

| Function or option | Default | What it does |
|---|---|---|
| `nerd-icons-statusline` | `#t` | When the package loads, add the file icon and git branch to the status line |
| `(set-nerd-icon! KIND KEY HEX)` | | Use the icon at code point `HEX` for `KEY` of `KIND` |

## Out of scope

- Shipping or choosing the font: the user's terminal or GUI font must have the Nerd Font icons.
- Coloured icons, as Emacs's nerd-icons gives each icon a face.
- Turning the icons off without restarting.
- Icons in the buffer's own text, such as Org headings or the start screen.

## Known gaps

- The status line's branch is read only when a buffer's major mode is set or it is renamed, so after `git checkout` or `git switch` it shows the old branch until the buffer is opened again.
- Setting `nerd-icons-statusline` after the package has loaded does nothing, either way.
