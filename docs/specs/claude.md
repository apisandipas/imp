---
status: accepted
summary: "Claude Code per project, in a terminal window on the right."
anchors: [runtime/claude.scm, crates/imp-server/tests/claude.rs]
---
# Claude Code

## Behaviour

- One `claude-command` terminal per project root, shown down the right (40%) by a popup rule. `M-a` shows it, or hides it from inside; the program keeps running. It is a toggled terminal, as the project's shell is ([[spec/terminals]]), with sending on top.
- `SPC a s`, `SPC a b` and `SPC a f` paste the selection or line, the buffer, or `@path` into its prompt as a bracketed paste, labelled `path:lines`.
- A new instance only gets text `claude-settle-ms` after it turns bracketed paste on, because Claude Code drops input sent before then.

## Keys and options

`claude-command`, `claude-settle-ms`.
