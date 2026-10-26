---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/55
summary: "The file-tree package: the project's folders as an expandable tree down the left, toggled with SPC t e."
---
# File tree

A bundled package ([[0011-non-essential-features-are-opt-in-packages]]): `(use-package! 'file-tree)`. It sits beside the [[dired]] file browser rather than replacing it: the tree is for finding your way around a project, and Dired for editing a directory as text.

## Behaviour

- `SPC t e` and `:FileTree` toggle the tree. It opens down the left of the frame, `file-tree-width` columns wide (30), and the cursor moves into it. Toggling it from anywhere, the tree included, closes it, and the cursor goes back to the window it came from. Each frame has at most one tree, so each client of the daemon has its own.
- The tree shows the current buffer's project root ([[projects]]), or the working directory outside a project. The root's name is on the first line, and below it, its entries are indented two columns a level. Directories come first and end in `/`, then files, each group in alphabetical order.
- When it opens, the tree expands down to the current buffer's file and puts the cursor on it.
- `<ret>` and `<tab>` on a directory expand or collapse it in place. `<ret>` on a file opens it in the window the tree was opened from, and moves the cursor there. Which directories are expanded is remembered while imp runs, so a tree that is closed and opened again looks the same.
- `a` asks for a new name inside the directory under the cursor (on a file, that file's directory). A name ending in `/` makes a directory, and missing parent directories are made too. The tree then shows it with the cursor on it.
- `r` asks for a new path for the entry under the cursor, filled in with its current path relative to the root. It renames or moves the entry, and a buffer visiting the file follows it.
- `D` deletes the entry under the cursor after `confirm!`. A directory is deleted with everything in it.
- Dotfiles and files git ignores are hidden at first. `H` shows or hides dotfiles, and `I` shows or hides ignored files. `file-tree-show-hidden` and `file-tree-show-ignored` set what the tree starts with.
- `R` reads the directories again; the tree also does this after `a`, `r` and `D`, and whenever it is opened. `q` closes the tree, as toggling it does.
- `?` shows a which-key popup of the tree's keys, and a second `?` hides it.
- With `file-tree-open-at-start` set (off by default), the tree opens beside the first window when imp starts, and the cursor stays in that window.
- The buffer is `*file-tree*`, read-only, in `file-tree-mode`. `j`, `k`, searching and the other Vim motions work in it as in any buffer.

## Keys and options

`SPC t e`, `:FileTree`, and in the tree `<ret> <tab> a r D H I R q ?`; `file-tree-width`, `file-tree-show-hidden`, `file-tree-show-ignored`, `file-tree-open-at-start`.

## Out of scope

- Drag and drop, and copy, cut and paste of files.
- A sliding animation when it opens or closes.
- Git status colours or file icons beside the entries. Planned in #78.
- More than one root, or a tree in more than one window of a frame. Planned in #78.
- Following the current buffer while the tree stays open: it reveals the file when it opens, not as you switch buffers. Planned in #78.

## Known gaps
