---
type: Decision
status: accepted
---
# Steel Scheme as the extension language

## Context
What imp takes from Emacs is that almost all of the editor is written in its own extension language and can be redefined while it runs. The language has to allow live redefinition, have macros and introspection, and embed in Rust. Lua (no macros) and TypeScript (not built for live redefinition) were considered.

## Decision
The extension language is Steel, a Scheme embedded in Rust (`steel-core`, pinned in `Cargo.toml`).

## Consequences
- Live redefinition, macros and introspection come with the language, and Steel embeds natively.
- Steel is young: builtins are missing and error messages are rough. Pin the version and upgrade deliberately. Its known gotchas are recorded beside the runtime.
- Redefinition needs care in Steel (a `define` of an existing name makes a new binding), which is why user code goes through `imp-eval-string`.
