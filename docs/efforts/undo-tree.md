---
type: Effort
status: done
specs: ["[[spec/vim]]"]
issue: https://github.com/apisandipas/imp/issues/5
frozen:
  docs/specs/vim.md: 7a2641f5642e
---
# Undo tree

Vim's undo tree, and marks put back by undo.

## Approach

`Buffer` keeps undo as a tree of states instead of two stacks. A state is a snapshot of the text (ropes share structure, so snapshots stay cheap, as now) and of the marks, with its parent, its change number, when it was made, and the child last visited. `undo_boundary` still commits the text as a new state when it changed since the last one, now as a child of the current state. `undo` goes to the parent, `redo` to the child last visited, and `undo_step` to the state with the next or previous change number. Moving to a state puts back the marks it saved; marks it doesn't know keep their place, clamped into the text. Scheme gets `undo-step!` and `undo-list`, and `vim.scm` binds `g-`, `g+` and `:undolist` with the `undo-command` that `u` and `C-r` use.

Decisions made while the owner was away (issue #5 had no answers yet): marks set after a state keep their place when moving to it; no undo by time, no undo files, no drawn tree; no cap on the number of states, as now.

## Tasks

- [x] `Buffer` undo as a tree with marks: `undo`, `redo`, `undo_step`, `undo_list`. Unit tests for branching, redo along the last branch, chronological steps across branches and marks put back.
- [x] Scheme: `undo-step!`, `undo-list`; `g-`, `g+` and `:undolist`. Tested in `vim.rs` or a new `undo.rs`, checked against Vim's `g-`/`g+` on a branching history.
- [x] Docs: the help for `u` and `C-r` mention the tree if they describe undo.
