---
type: Effort
status: planned
specs: ["[[spec/folding]]"]
issue: https://github.com/apisandipas/imp/issues/48
frozen:
  docs/specs/folding.md: 2596f3a5ab7f
---
# Fold column and VSCode-style folds

Folds by indent in file buffers, open at first, headers inside indent folds, and a clickable fold column ([[0014-folds-work-like-vscode-s-keys-like-vim-s]]).

## Approach

The fold model in `fold.scm` stays; what changes is which folds `foldmethod.scm` wants, its defaults, and what the renderer is told. Indent ranges grow by the line above them. The defaults are set when a buffer opens, after its major mode is picked, so a mode that sets `foldmethod` itself (Org) wins. The renderer only knows closed folds today (`set-closed-folds!`); it is replaced by `set-folds!`, which takes every fold with its state, so Rust can work out both the lines closed folds hide and where chevrons go. One general primitive rather than a second one beside it, per [[0005-rust-owns-data-and-speed-scheme-owns-behavior]]. The column is laid out in the gutter like the sign column, with an Auto/Yes/No enum, and a click is told apart from a text click by a primitive that says whether a screen cell is on a window's fold column and for which line; `mouse.scm` decides what the click does.

## Tasks

- [ ] Indent folds include the line above that opens them (none for a run at the top); `expr` unchanged. Tests in `tests/foldmethod.rs` updated and added.
- [ ] `foldlevel` defaults to 99; a buffer visiting a file of at most 10,000 lines starts with `foldmethod` indent unless its major mode set one, Org keeps `manual`, other buffers `manual`. Tests for each case.
- [ ] `set-folds!` replaces `set-closed-folds!`, and the renderer draws the fold column between numbers and text: `▾`/`▸` on the outermost fold starting on a line, first row of a wrapped line only, the `foldcolumn` option (`auto`/`yes`/`no`, buffer-local) and the `fold-column` face. Render tests.
- [ ] A click on a chevron toggles that fold, leaving the cursor unless the fold closes over it (then its first line); a click on a blank column cell acts as a click on the line's number. Tests.
- [ ] Checked by hand in both clients by the owner; `crates/imp-server/CONTEXT.md` or `runtime/CONTEXT.md` updated if their rules changed.
