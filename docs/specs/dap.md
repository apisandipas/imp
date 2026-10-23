---
status: accepted
summary: "Debugging through debug adapters: breakpoints, stepping, the stack and variables."
anchors: [runtime/dap.scm, crates/imp-server/tests/dap.rs]
---
# DAP

## Behaviour

- Adapters per major mode: lldb-dap for Rust, C and C++ (asking for the program, with Cargo's debug build suggested), debugpy for Python.
- Breakpoints are marks, so they follow edits, shown as `●` signs. The stopped line is highlighted (`debug-line`) and marked `→`. Gutter signs merge by priority: diagnostics, then breakpoints, then the stopped line.
- `SPC d`: `d` start or continue, `b` breakpoint, `n i o` step over, in, out, `s` stack, `v` variables, `e` evaluate, `q` stop; also `<f5> <f9> <f10> <f11>`.

## Keys and options

- `(define-debug-adapter! 'mode "command" "adapter-id" (lambda (done) (done launch-arguments)))`.

## Known gaps

- One session at a time, and stdio adapters only (codelldb and js-debug need TCP).
- No conditional breakpoints or watches, and nested variables don't expand beyond `SPC d e`.
