---
type: Effort
status: active
specs: ["[[spec/git-gutter]]", "[[spec/buffers-and-windows]]"]
issue: https://github.com/apisandipas/imp/issues/53
frozen:
  docs/specs/git-gutter.md: 9ae046f51d02
  docs/specs/buffers-and-windows.md: 21bd8d3245c3
---
# Git gutter package

Lines that differ from git's index get a coloured bar in a change column of their own.

## Approach

Two Rust primitives, then a package in Scheme ([[0005-rust-owns-data-and-speed-scheme-owns-behavior]]). `line-diff` compares two texts line by line (Myers' algorithm) and gives the changed blocks as git's `-U0` hunks would, so the buffer's unsaved text can be compared with the index without temporary files: git only has to print the index's copy (`git show :path`), in the background. `set-change-marks!` gives the current buffer a one-cell change column between the line numbers and the fold column ([[0016-git-changes-take-their-own-gutter-column-not-the-sign-column]]). The package `packages/git-gutter` turns the hunks into marks and keeps them current, as `git-blame` does with its timer.

## Tasks

- [x] `line-diff` gives the changed blocks between two texts as (old-start old-count new-start new-count), with Rust tests for adds, removes, changes, the start and end of a file, and a missing final newline.
- [x] `set-change-marks!` draws a one-cell change column between the line numbers and the fold column (#f takes it away); clicks on the fold column still land, and the buffers-and-windows spec names it, with tests.
- [x] The `git-gutter` package (in `PACKAGES`) turns on `git-gutter-mode` in tracked files and marks added, changed and removed lines against the index, refreshing on open, after `git-gutter-delay`, after save and on buffer-enter, with tests on a temporary repository.
- [x] `]h` and `[h` move between changed blocks with a count, and `:GitGutter` turns the mode off and on, with tests.
- [ ] The package's header comment says how to use it; the owner has tried it by hand.
