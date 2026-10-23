---
type: Decision
status: accepted
anchors: ["runtime/core.scm"]
---
# Config in init.scm

## Context
Users configure an Emacs-like editor in its own language.

## Decision
The user's config is `~/.config/imp/init.scm` (or `$XDG_CONFIG_HOME/imp/init.scm`), Scheme, mirroring Emacs's `init.el`. It loads after the runtime; an error in it goes to the status line and the editor still starts.

## Consequences
- Configuration and extension are the same thing: anything the runtime does, `init.scm` can redefine.
