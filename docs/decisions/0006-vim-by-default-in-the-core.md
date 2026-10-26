---
type: Decision
status: accepted
anchors: ["runtime/vim.scm"]
---
# Vim by default, in the core

## Context
Evil retrofits Vim onto modeless Emacs, and its edge cases show the cost. Vim users leave the moment their habits break.

## Decision
imp is Vim-first: the modal model is part of the key and command design from the start, not added on. An Emacs state exists as a supported alternative.

## Consequences
- Vim behavior is matched against real Vim and Neovim, and tested by feeding keys.
- Extension points (motions, operators, text objects) are built around Vim's grammar, so new ones work with counts, `.` and visual mode.
