---
type: Decision
status: accepted
---
# Rust for the core

## Context
imp needs a core that handles text, rendering, parsing and third-party protocol code (tree-sitter grammars, language servers, debug adapters) quickly and without crashing on bad input.

## Decision
The core is written in Rust.

## Consequences
- The ecosystem covers what the core needs: ropey for text, tree-sitter, crossterm for the terminal, wgpu for the window, regex.
- Memory safety around third-party code comes from the language rather than from care.
- Rust code is slower to change than Scheme, which is one more reason behavior lives in Scheme ([[0005-rust-owns-data-and-speed-scheme-owns-behavior]]).
