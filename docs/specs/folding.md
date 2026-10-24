---
status: accepted
issue: https://github.com/apisandipas/imp/issues/11
summary: "Vim's folds, manual or by indent, syntax or expression, drawn by the renderer."
anchors: [runtime/fold.scm, crates/imp-server/tests/foldmethod.rs, crates/imp-server/tests/folds.rs]
---
# Folding

## Behaviour

- A fold is a line range kept as two marks, so it follows edits; the end mark sits at the start of the line after, so deleting a fold's last line shrinks it.
- A closed fold draws as its first line with a `··· N lines` note. Scrolling, wrap, clicks and relative numbers account for it.
- Keys: `zf` (an operator), `zF`, `zo zO zc zC za zA zR zM zE zd zD zj zk`, and `:fold`, `:foldopen[!]`, `:foldclose[!]`.
- `j`, `k` and counts step over a closed fold as one line, and linewise operators take it whole.
- Folds open where Vim's default 'foldopen' says: after searches, marks, `%`, `{ }`, undo, and horizontal motions.
- Folds nest.
- **foldmethod** (buffer-local with `:setlocal`): `manual` (the default), `indent`, `syntax` or `expr`, as in Vim.
  - `indent`: a line's fold level is its indent divided by `shiftwidth`; a blank line takes the lower level of the lines around it. Each run of lines at level n or deeper is a fold, so folds nest and the line that opens a block stays in view, as in Vim.
  - `syntax`: a fold for each tree-sitter node over several lines whose kind is one of the language's functions or classes (the kinds `af` and `ac` use), or the kinds `(define-syntax-folds! "language" '("kind" ...))` gives. The fold takes the node's lines, its first included.
  - `expr`: `(set-local-option! 'foldexpr (lambda (line) level))` gives each line's level, folded as for `indent`.
  - Folds are worked out again after each change outside insert state and when insert ends. A fold still there keeps its open or closed state. When `foldmethod` is set, folds deeper than `foldlevel` (0 by default, as in Vim) start closed; folds that appear later start open.
  - With a method other than `manual`, `zf`, `zF`, `zd`, `zD` and `zE` say they can't; opening and closing work as ever. Setting `foldmethod` back to `manual` keeps the folds, as manual ones.
- Org builds its outline on these folds ([[org]]).

## Out of scope

- The `marker` and `diff` methods, `zm`, `zr`, `foldlevelstart`, `foldminlines` and `foldnestmax`.
