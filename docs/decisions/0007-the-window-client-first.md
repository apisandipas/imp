---
type: Decision
status: accepted
anchors: ["crates/imp/src/main.rs", "crates/imp-gui/**"]
---
# The window client first

## Context
imp was built terminal first because it was cheaper. The window client (winit, wgpu, glyphon) began as a prototype.

## Decision
Since 0.1.0-alpha.1, `imp` opens a window. `--tui` asks for the terminal, and imp falls back to it when no window can open (no display, or over SSH).

## Consequences
- Window-only things (text heights, divider widths, fonts, opacity) are first-class, and the protocol carries them for clients that ask.
- The terminal must keep working on its own: a build without the `gui` feature is terminal-only, and window-only flags are an error there.
