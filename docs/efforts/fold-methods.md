---
type: Effort
status: active
specs: ["[[spec/folding]]"]
issue: https://github.com/apisandipas/imp/issues/11
frozen:
  docs/specs/folding.md: 40fb000d6a72
---
# Fold methods

`foldmethod` by indent, syntax or expression, on top of the manual folds.

## Approach

Automatic folds are ordinary folds (two marks each), so drawing, `j`/`k`, operators and the fold keys need nothing new. A buffer with a method other than manual works out the folds it should have, as line ranges, and syncs its folds to them: a fold whose range is still wanted stays, with its state; the rest go; new ranges become folds. Indent and expr give a level per line, and the folds are the runs at each level; syntax gets multi-line node ranges from one new Rust primitive (`syntax-fold-lines`) rather than walking the tree from Scheme. Folds are synced when `foldmethod` changes (honouring `foldlevel`), in `post-command` when the text changed outside insert state, and on `insert-leave`. Manual-only keys check the method.

Decisions made while the owner was away (issue #11 had no answers yet): `foldlevel` 0 by default as in Vim, so folds start closed when the method is set; later folds start open; syntax folds default to the function and class kinds the text objects already know; `expr` takes a Scheme procedure, not a Vim expression; folds aren't updated while typing in insert state.

## Tasks

- [x] `foldmethod`, `foldlevel` and `foldexpr` options; syncing folds to wanted ranges; `indent` and `expr`. Tested in a new `foldmethod.rs`, including nesting, blank lines, edits keeping a closed fold closed, and `foldlevel`.
- [ ] `syntax`: `syntax-fold-lines` in Rust, `define-syntax-folds!`, default kinds from the text objects. Tested on Rust code.
- [ ] Manual-only keys refuse under another method; back to manual keeps the folds. Tested.
- [ ] Docs: `runtime/CONTEXT.md` extension points name `define-syntax-folds!`.
