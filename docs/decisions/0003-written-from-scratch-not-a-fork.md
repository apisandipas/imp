---
type: Decision
status: accepted
---
# Written from scratch, not a fork

## Context
Helix (with its Steel plugin branch) and Lem are the closest existing editors. Forking one would have been faster to start.

## Decision
imp is written from scratch, using libraries. Helix, Lem, Evil and Neovim are read as references only. The owner chose this explicitly.

## Consequences
- imp's architecture (modal model in the core, behavior in Scheme, client/server) isn't bent around another editor's.
- Everything a fork would have given for free has to be built, which is what the phases did.
- Helix uses Kakoune's select-then-act grammar, not Vim's, so its behavior is never the reference for keys; Vim's is ([[0006-vim-by-default-in-the-core]]).
