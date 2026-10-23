---
status: accepted
summary: "Sandboxed WASM plugins as Vim operators and commands, behind the wasm feature."
anchors: [runtime/wasm.scm, crates/imp-server/src/wasm.rs, crates/imp-server/tests/wasm.rs, examples/wasm-plugin/**]
---
# WASM plugins

A prototype of a second plugin tier, for heavy work or code you don't want running with full trust. Scheme stays the main extension language. Off unless built with `--features wasm`.

## Behaviour

- Plugins are core WebAssembly modules (wasmtime) with a string ABI: a plugin exports `memory` and `imp_alloc(len)`; a function takes the `(ptr, len)` of a UTF-8 string and returns `ptr << 32 | len` of its result. The one import is `imp.log`.
- No WASI: no files, network or clock. A fuel budget per call and a memory limit per plugin turn a runaway plugin into an error.
- `wasm-operator` (a Vim operator), `define-wasm-filter!` (a command over the selection or buffer, one undo step), `:[range]wasm`, `:wasm-log`. `examples/wasm-plugin` is a Rust plugin that converts case.
- Without the feature, the primitives exist and fail with "imp was built without the wasm feature".

## Out of scope

- The component model (needs `wasm32-wasip2` and `cargo-component`); the ABI is small enough to swap for WIT later.
