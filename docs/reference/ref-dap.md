---
type: Page
spec: "[[spec/dap]]"
frozen:
  docs/specs/dap.md: b1a36380474b
---
# Debugging

imp runs your program under a debugger, so you can stop it at a line, step through it and look at its variables. It talks to a debug adapter, a program that drives the debugger for one language.

## Not yet in imp

- Only one debug session runs at a time.
- Only adapters that talk over standard input and output work, so codelldb and js-debug, which need a network port, don't.
- There are no conditional breakpoints and no watches. Nested variables don't expand: evaluate them with `SPC d e` to see inside.

## Adapters imp knows

| Language | Adapter |
|---|---|
| Rust, C and C++ | `lldb-dap` |
| Python | `debugpy` |

For Rust, C and C++, imp asks which program to run, and suggests Cargo's debug build. For Python, it runs the current file.

## Breakpoints and stepping

Press `SPC d b` on a line to set a breakpoint, and again to remove it. A breakpoint shows as `●` in the gutter and stays on its line as you edit. Then press `SPC d d` to start the program.

When the program stops, the line it stopped on is highlighted and marked `→`. Where a line has more than one sign, the `→` shows over a `●`, and a `●` over a diagnostic.

| Key | What it does |
|---|---|
| `SPC d d` or `<f5>` | Start the program, or continue it when stopped |
| `SPC d b` or `<f9>` | Set or remove a breakpoint on this line |
| `SPC d n` or `<f10>` | Step over |
| `SPC d i` or `<f11>` | Step in |
| `SPC d o` | Step out |
| `SPC d q` | Stop the program |

## Looking around

| Key | What it does |
|---|---|
| `SPC d s` | Pick a frame of the stack and go to its source |
| `SPC d v` | Show the variables of that frame |
| `SPC d e` | Evaluate an expression in that frame |

## An adapter of your own

Set a major mode's adapter in `init.scm`. Give the command that runs it, its adapter id, and a procedure that passes the launch settings to `done`:

```scheme
(define-debug-adapter! 'python-mode "python3 -m debugpy.adapter" "debugpy"
  (lambda (done) (done (hash "program" (absolute-path (buffer-path))))))
```

The procedure can ask you something first, and call `done` with your answer.
