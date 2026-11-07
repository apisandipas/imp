---
type: Effort
status: active
specs: ["[[spec/file-tree]]"]
issue: https://github.com/apisandipas/imp/issues/180
frozen:
  docs/specs/file-tree.md: 4e9aa0372390
---
# File tree sidebar polish

Issue #180: a click opens a file without leaving the tree, roots stand out, and buffer cycling leaves the tree alone.

## Approach

Three small changes, one task each, plus the docs.

The click and the roots stay inside `packages/file-tree/file-tree.scm`. The click hook calls a variant of `file-tree-visit!` that opens the file in the origin window and then returns to the tree. Roots get a `file-tree.root` face (bold, `height=1.2`), set on their line in `file-tree-decorate!`. A blank row goes before every root but the first, and `file-tree-row` returns nothing for it, so `<ret>`, `a`, `r`, `D`, `X` and clicks do nothing there.

Buffer cycling needs a hook in core, because `:bn` and `:bp` live in `runtime/vim.scm` and the package can't reach them. The primitive is generic and not tied to the tree: `buffer-step` skips a buffer whose buffer-local `buffer-cycle-skip` is set, and when the current buffer has a buffer-local `buffer-cycle-window` procedure, `:bn` and `:bp` cycle in the window it returns and then come back. The tree sets both on its buffer. `next-buffer` and `previous-buffer` already run `:bn` and `:bp`, so `SPC b n`, `SPC b p` and the Emacs keys follow.

## Tasks

- [x] A click on a file opens it in the origin window, and the cursor stays in the tree on that file. `<ret>` doesn't change. Update `clicks_open_folders_and_files` and add a test that the tree window is still focused.
- [ ] Root lines in the new `file-tree.root` face (bold, `height=1.2`), and a blank line before each added root. `<ret>`, `a`, `r`, `D`, `X` and a click on the blank line do nothing. Test both in `file_tree.rs`, and update the tests that count lines with more than one root (`p_adds_roots_and_x_removes_them`).
- [ ] Core: `buffer-step` skips buffers with `buffer-cycle-skip`, and `:bn`/`:bp` from a buffer with `buffer-cycle-window` cycle in that window and keep the cursor where it was. The tree sets both. Test that `SPC b n` from the tree changes the origin window's buffer while the tree stays focused and follows, and that `:bn` from the origin window never lands on `*file-tree*`.
- [ ] Docs: each task above updates `docs/reference/ref-file-tree.md` in its own commit; here, read the whole page against the spec with the docs-page skill and stamp it, read `docs/guide/packages.md` against the change and stamp it, and update the package's header comment.
