---
status: accepted
summary: "Vim's manual folds, drawn by the renderer."
anchors: [runtime/fold.scm, crates/imp-server/tests/folds.rs]
---
# Folding

## Behaviour

- A fold is a line range kept as two marks, so it follows edits; the end mark sits at the start of the line after, so deleting a fold's last line shrinks it.
- A closed fold draws as its first line with a `··· N lines` note. Scrolling, wrap, clicks and relative numbers account for it.
- Keys: `zf` (an operator), `zF`, `zo zO zc zC za zA zR zM zE zd zD zj zk`, and `:fold`, `:foldopen[!]`, `:foldclose[!]`.
- `j`, `k` and counts step over a closed fold as one line, and linewise operators take it whole.
- Folds open where Vim's default 'foldopen' says: after searches, marks, `%`, `{ }`, undo, and horizontal motions.
- Org builds its outline on these folds ([[org]]).

## Known gaps

- Manual folds only: no 'foldmethod' by syntax, indent or expression.
- Folds don't nest.
