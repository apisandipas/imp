---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/53
summary: "The git-gutter package: a coloured bar beside each line that differs from git's index, as VSCode and gitsigns show them."
anchors: [packages/git-gutter/git-gutter.scm, crates/imp-server/tests/git_gutter.rs]
---
# Git gutter

The git-gutter package marks each line of a file that differs from git with a coloured bar beside it, as VSCode, gitsigns and diff-hl do. It is a bundled package ([[0011-non-essential-features-are-opt-in-packages]]), loaded with `(use-package! 'git-gutter)`.

## Behaviour

- Loading it turns on `git-gutter-mode` in every buffer visiting a file that git tracks, as it opens.
- In `git-gutter-mode` the buffer has a change column one cell wide, between the line numbers and the fold column ([[0016-git-changes-take-their-own-gutter-column-not-the-sign-column]]). The column stays while the mode is on, even with no changes, so the text doesn't shift as lines change and change back.
- The buffer's text is compared with the file in git's index, as gitsigns does, so staged changes aren't marked.
  - An added line gets `┃` in the `git-gutter.added` face (green).
  - A changed line gets `┃` in `git-gutter.changed` (orange). Every new line of a block that replaced old lines counts as changed.
  - Removed lines have no line of their own. The line above them gets `▁` in `git-gutter.removed` (red), or the first line gets `▔` when they were at the top.
- The marks follow the buffer's text as it is, unsaved edits included.
  - They are worked out when the file opens, `git-gutter-delay` milliseconds (300) after the last change, after a save, and when the buffer is shown again (the index may have changed).
  - git runs in the background, and the lines are compared in Rust ([[0005-rust-owns-data-and-speed-scheme-owns-behavior]]).
- `]h` and `[h` move to the first line of the next and previous changed block, taking a count. Past the last one they stay put and say `no more hunks`.
- `M-x git-gutter-mode` turns it off and on in the current buffer. Off, the column and its marks go.
- A file outside a repository, or one git doesn't track, gets no column.

## Keys and options

`]h`, `[h`, `git-gutter-mode`, `git-gutter-delay`, the faces `git-gutter.added`, `git-gutter.changed` and `git-gutter.removed`.

## Out of scope

- Staging, reverting or previewing a hunk from the buffer.
- Comparing with `HEAD` or another commit instead of the index.
- Marking an untracked file's lines as added.
- Changes within a line (word diff).

## Known gaps
