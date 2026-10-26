---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/55
follow-up: https://github.com/apisandipas/imp/issues/78
anchors: [packages/file-tree/file-tree.scm, crates/imp-server/tests/file_tree.rs]
summary: "The file-tree package: the project's folders as an expandable tree down the left, toggled with SPC t e."
---
# File tree

A bundled package ([[0011-non-essential-features-are-opt-in-packages]]): `(use-package! 'file-tree)`. It sits beside the [[dired]] file browser rather than replacing it: the tree is for finding your way around a project, and Dired for editing a directory as text.

## Behaviour

- `SPC t e` and `:FileTree` toggle the tree. It opens down the left of the frame, `file-tree-width` columns wide (30), and the cursor moves into it. Toggling it from anywhere, the tree included, closes it, and the cursor goes back to the window it came from. Each frame has at most one tree, so each client of the daemon has its own, in its own buffer.
- The tree shows one or more roots. The first is the current buffer's project root ([[projects]]) when the tree opens, or the working directory outside a project. Each root's name is on a line of its own, and below it, its entries are indented two columns a level. Directories come first and end in `/`, then files, each group in alphabetical order.
- `P` adds another root: a project picked from the remembered projects with completion, or a directory typed in. Added roots come after the first, in the order they were added, and are remembered between sessions in imp's state directory. `X` on an added root's line removes it from the tree (the directory stays). The first root can't be removed, and a root added twice is shown once.
- When it opens, the tree expands down to the current buffer's file and puts the cursor on it.
- With `file-tree-follow` on (the default), switching to a buffer whose file is under one of the roots, in any window, expands the tree down to it and moves the tree's cursor to it. The cursor stays in the window you switched in. A file under no root changes nothing.
- `<ret>` and `<tab>` on a directory expand or collapse it in place. `<ret>` on a file opens it in the window the tree was opened from, and moves the cursor there. Which directories are expanded is remembered while imp runs, so a tree that is closed and opened again looks the same.
- `a` asks for a new name inside the directory under the cursor (on a file, that file's directory). A name ending in `/` makes a directory, and missing parent directories are made too. The tree then shows it with the cursor on it.
- `r` asks for a new path for the entry under the cursor, filled in with its current path relative to its root. It renames or moves the entry, and a buffer visiting the file follows it.
- `D` deletes the entry under the cursor after `confirm!`. A directory is deleted with everything in it.
- Dotfiles and files git ignores are hidden at first. `H` shows or hides dotfiles, and `I` shows or hides ignored files. `file-tree-show-hidden` and `file-tree-show-ignored` set what the tree starts with.
- In a git repository, changed entries show their status: the name in a face, and a letter after it, as end-of-line text ([[buffers-and-windows]]). `M` (`file-tree.modified`) is a file changed in the index or the work tree, `A` (`file-tree.added`) a new file in the index, `U` (`file-tree.untracked`) an untracked one, and `!` (`file-tree.conflict`) a conflict. A folder holding changes, open or shut, takes the face of the most serious one inside it (a conflict, then a change, then a new file), with no letter. An ignored file, when shown, is in `file-tree.ignored`. Outside a repository, no entry has a status.
- With the nerd-icons package loaded, each entry has its file-type icon before its name, and a folder an open or shut folder icon. The icon is part of the line, between the indent and the name, and the cursor sits on the name.
- `R` reads the directories and git status again; the tree also does this after `a`, `r` and `D`, after a file under one of its roots is saved, and whenever it is opened. Git runs in the background, so the tree is drawn first and its statuses follow. `q` closes the tree, as toggling it does.
- `?` shows a which-key popup of the tree's keys, and a second `?` hides it.
- With `file-tree-open-at-start` set (off by default), the tree opens beside the first window when imp starts, and the cursor stays in that window.
- The buffer is `*file-tree*`, read-only, in `file-tree-mode`. While another client of the daemon has a tree open, a new one is `*file-tree 2*` and so on; a tree's buffer goes when the tree closes. `j`, `k`, searching and the other Vim motions work in it as in any buffer.

## Keys and options

`SPC t e`, `:FileTree`, and in the tree `<ret> <tab> a r D H I P X R q ?`; `file-tree-width`, `file-tree-show-hidden`, `file-tree-show-ignored`, `file-tree-open-at-start`, `file-tree-follow`; the faces `file-tree.modified`, `file-tree.added`, `file-tree.untracked`, `file-tree.conflict` and `file-tree.ignored`.

## Out of scope

- Drag and drop, and copy, cut and paste of files.
- A sliding animation when it opens or closes.
- More than one tree in a frame: more roots cover that need.
- Staging, committing or other git actions from the tree; the git status buffer does those ([[git]]).
- Git status for deleted files, which aren't in the tree to show it.

## Known gaps
