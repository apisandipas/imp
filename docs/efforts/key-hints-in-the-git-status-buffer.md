---
type: Effort
status: active
specs: ["[[spec/git]]", "[[spec/buffers-and-windows]]"]
issue: https://github.com/apisandipas/imp/issues/2
frozen:
  docs/specs/git.md: 78d3f472e9c2
  docs/specs/buffers-and-windows.md: 739ec3143f3e
---
# Key hints in the Git status buffer

Two key lines pinned at the bottom of the status window, `?` as a menu that runs the key pressed, and one key table behind both.

## Approach

The key lines sit at the bottom of the window, as Magit's transients do, so they stay in view however far the status scrolls. imp has nothing that pins lines to a window, so a general footer comes first: `set-footer!` gives the current buffer lines of (text face) parts, and the renderer draws them above the status line of every window showing the buffer, taking rows from its text. One small primitive any special buffer can use, per [[0005-rust-owns-data-and-speed-scheme-owns-behavior]]; the log and diff buffers can have footers later. Everything about Git stays in `runtime/git.scm`: the status keys become one table of (key label action), bound with `git-keys!` (labels to which-key) and read by `?`, a `menu!` whose entries call each key's action with a count of 1, and by the footer, replacing the hand-typed `git-help-lines`.

## Tasks

- [x] `set-footer!` gives the current buffer footer lines; each window showing it draws them above its status line, cut to its width, with fewer rows for text (scrolling, the cursor and clicks account for it), and leaves them out with fewer than two text rows beside them; `'()` removes them. Tests in `tests/windows.rs`: drawn at the bottom while scrolled, the cursor kept above them, a short window without them.
- [x] The status keys are one table of (key label action) that `git-keys!` binds, labels going to which-key; `?` opens a `menu!` of every key in it but `?`, and the key pressed runs on the item at the cursor; `git-help-lines` goes. Tests in `tests/git.rs`: `?` then `s` stages a file, `?` then `c` opens the commit menu.
- [ ] The status buffer's footer: the two key lines, labels from the table, keys in a new `git.key` face; `git-status-hints` (#t) leaves them out. Tests: the lines are at the bottom of the window, and the option hides them.
- [ ] Checked by hand by the owner: add, commit and push, and pull, using only the keys shown.
