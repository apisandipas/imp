---
type: Decision
status: accepted
anchors: ["crates/imp-server/src/api/**"]
---
# Rust owns data and speed, Scheme owns behavior

## Context
The test stated early: if most of the editor isn't written in the extension language, imp is VS Code, not Emacs. But some paths (keystroke dispatch, scans, fuzzy matching, regex) can be too slow in Scheme.

## Decision
Buffers, rendering and parsing are Rust. Every command, keymap and mode is Scheme, the Vim engine included: Rust doesn't know what a key means. A Rust primitive in `api.rs` is added only when Scheme can't do the job or measures too slow, and it stays small and general.

## Consequences
- New editing behavior goes in Scheme; the Rust/Scheme line is `api.rs`.
- Measure (`examples/bench.rs`) before moving anything to Rust, and prefer a faster primitive over moving behavior.
- The temptation to move slow Scheme into Rust is the main risk to the design, and this decision is the check on it.
