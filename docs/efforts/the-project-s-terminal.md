---
type: Effort
status: active
specs: ["[[spec/terminals]]"]
issue: https://github.com/apisandipas/imp/issues/85
frozen:
  docs/specs/terminals.md: 50e895cf4812
---
# The project's terminal

## Approach

The toggle is Claude's (`runtime/claude.scm`), lifted into `runtime/term.scm`, which loads before it: a table per toggle of project root to buffer, `display-buffer!` for the popup rule, hiding by closing the popup window (or going back to the alternate buffer when it's the only window), and starting again in a fresh buffer once the program has exited. Each toggled buffer carries its toggle's name and root as buffer locals, so the same key knows it's inside. `define-toggled-terminal!` defines the command and returns nothing more; `toggled-terminal-show!` and `toggled-terminal-buffer` are there for Claude, which needs the buffer to send to. The shell's toggle is the first user, so the generic piece is built and tested on it before Claude moves over, keeping Claude's tests as they are as the check that nothing changed for it.

## Tasks

- [x] `define-toggled-terminal!` in `runtime/term.scm`, and `toggle-terminal` on it: `SPC o t` and `` M-` `` (every state, TERMINAL included) show the project's shell down the right at 40% (popup rule `"*terminal:"`), started in the project root, or imp's current directory outside a project; the same key from inside hides it and the shell keeps running; after it exits, the toggle starts a new one; `*terminal: PROJECT*` names it. `SPC o T` is `terminal`. A command option symbol for `COMMAND`. Tests for each, and for a toggle of your own (`define-toggled-terminal!` with a stand-in program); the terminals reference page, the leader reference's `SPC o` keys, the README, and `runtime/CONTEXT.md`'s extension points.
- [ ] Claude on `define-toggled-terminal!`: `claude.scm` keeps sending and waiting for its prompt, and its show, hide and per-project table come from `term.scm`; `tests/claude.rs` passes unchanged. The Claude spec and reference page say it's a toggled terminal.
