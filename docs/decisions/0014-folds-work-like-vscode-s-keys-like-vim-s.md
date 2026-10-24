---
type: Decision
status: accepted
anchors: [runtime/foldmethod.scm]
---
# Folds work like VSCode's, keys like Vim's

## Context

imp's folds began as Vim's ([[folding]], issue #11): `manual` unless set, `foldlevel` 0 so folds start closed, and indent folds that leave the line opening a block outside the fold. Reviewing that, the owner wanted folds to be something you see and click, as in VSCode, in both clients (issue #48). Vim offers a `foldcolumn` but keeps its defaults, and with them an editor that has no folds until configured, then hides everything at once. The alternative was Vim's defaults with a column added, which would show nothing until the user set a method.

## Decision

A buffer visiting a file folds by `indent` unless its major mode says otherwise or it is over 10,000 lines; folds start open (`foldlevel` 99); an indent fold includes the line above that opens it, so a closed block is one line; and a fold column of chevrons sits between the numbers and the text, toggled by a click. Vim's fold keys and the other methods stay as they are, `expr` folding as Vim does.

## Consequences

- Most code files show chevrons as soon as they open, in the terminal as clickable cells.
- Departs from Vim ([[0006-vim-by-default-in-the-core]]) in defaults and in where an indent fold starts: `zc` on a block's first line closes it, and `dd` on a closed one deletes the block with its header. Users who want Vim's behaviour set `foldmethod=manual foldlevel=0 foldcolumn=no`.
- Every file buffer works out folds after each change outside insert state; the 10,000-line limit bounds that cost.
- Major modes whose folds mean something else (Org's outline) must keep `manual`.
