---
status: accepted
issue: https://github.com/apisandipas/imp/issues/48
summary: "Folds by indent unless set otherwise, a clickable fold column, and Vim's fold keys."
anchors: [runtime/fold.scm, runtime/foldmethod.scm, crates/imp-server/tests/foldmethod.rs, crates/imp-server/tests/folds.rs, crates/imp-server/tests/fold_column.rs]
---
# Folding

## Behaviour

- A fold is a line range kept as two marks, so it follows edits; the end mark sits at the start of the line after, so deleting a fold's last line shrinks it.
- A closed fold draws as its first line with a `··· N lines` note. Scrolling, wrap, clicks and relative numbers account for it.
- Keys: `zf` (an operator), `zF`, `zo zO zc zC za zA zR zM zE zd zD zj zk`, and `:fold`, `:foldopen[!]`, `:foldclose[!]`.
- `j`, `k` and counts step over a closed fold as one line, and linewise operators take it whole.
- Folds open where Vim's default 'foldopen' says: after searches, marks, `%`, `{ }`, undo, and horizontal motions.
- Folds nest.
- **Fold column**: between the line numbers and the text, two cells wide: `▾` on the first line of an open fold, `▸` on a closed one, blank elsewhere; on a wrapped line, only its first row. When several folds start on a line it shows the outermost. The `foldcolumn` option (buffer-local) is `auto` (the default: shown while the buffer has a fold), `yes` or `no`; its face is `fold-column`.
- A click on a chevron opens or closes that fold, as `za` there would, and leaves the cursor where it is unless the fold closes over it, which puts it on the fold's first line. A click on a blank cell of the column does what a click on the line's number does.
- **foldmethod** (buffer-local with `:setlocal`): `manual`, `indent`, `syntax` or `expr`. A buffer visiting a file starts with `indent`, unless its major mode sets its own (Org keeps `manual` for its outline); other buffers, and files over 10,000 lines (where working out folds after each change would lag), start with `manual`; `:setlocal foldmethod=indent` still works on them.
  - `indent`: a line's fold level is its indent divided by `shiftwidth`; a blank line takes the lower level of the lines around it. Each run of lines at level n or deeper, with the line above it that opens it, is a fold, so a closed block shows as that line and its note (`fn main() {  ··· 4 lines`), as in VSCode rather than Vim. A run at the top of the buffer has no line above and folds alone. Folds nest.
  - `syntax`: a fold for each tree-sitter node over several lines whose kind is one of the language's functions or classes (the kinds `af` and `ac` use), or the kinds `(define-syntax-folds! "language" '("kind" ...))` gives. The fold takes the node's lines, its first included.
  - `expr`: `(set-local-option! 'foldexpr (lambda (line) level))` gives each line's level, folded as Vim folds them: each run at level n or deeper, without a line above.
  - Folds are worked out again after each change outside insert state and when insert ends. A fold still there keeps its open or closed state. When `foldmethod` is set, folds deeper than `foldlevel` start closed; `foldlevel` is 99 by default, unlike Vim's 0, so folds start open. Folds that appear later start open.
  - With a method other than `manual`, `zf`, `zF`, `zd`, `zD` and `zE` say they can't; opening and closing work as ever. Setting `foldmethod` back to `manual` keeps the folds, as manual ones.
- Org builds its outline on these folds ([[org]]).

## Out of scope

- Chevrons that show only while the mouse is over the column, as VSCode's do; the terminal client gets no mouse movement without a button held. Vim's numeric `foldcolumn` and its `│` nesting bars.
- The `marker` and `diff` methods, `zm`, `zr`, `foldlevelstart`, `foldminlines` and `foldnestmax`.
