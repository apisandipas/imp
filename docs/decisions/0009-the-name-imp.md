---
type: Decision
status: accepted
---
# The name imp

## Context
The editor needed a short name. `grimoire` was liked but `grim` collides with the owner's Wayland screenshot tool.

## Decision
It is called imp, a minor demon: evil (Vim in Emacs) plus daemon. The crate is published as `imp-editor`, since `imp` is taken on crates.io; the binary is `imp`.

## Consequences
- Commands, packages and the config keep plain names.
