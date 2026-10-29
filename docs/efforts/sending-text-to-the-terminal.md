---
type: Effort
status: planned
specs: ["[[spec/terminals]]"]
issue: https://github.com/apisandipas/imp/issues/86
frozen:
  docs/specs/terminals.md: 01ca620df0d2
---
# Sending text to the terminal

## Approach

The sending half of Claude's code moves to `runtime/term.scm`: `bracketed` and a `terminal-paste!` that sends text to a terminal as a bracketed paste when the program asked for one, typed otherwise, with a final line break dropped and `<ret>` after it on request. The project's terminal is shown without taking focus: started (if need be) in its popup window, then focus goes back to the window you were in, in the state you were in. A shell that has just started gets its text once it has printed something, looked for every so often for a few seconds, as Claude's sends wait for its prompt. Claude's own waiting (for bracketed paste, then a settling delay) stays in `claude.scm`, which then pastes with `terminal-paste!` and no `<ret>`. Tests use a stand-in for the shell that shows the escapes it gets, as `tests/claude.rs` does.

## Tasks

- [ ] `terminal-paste!`, and `SPC o s` (`terminal-send-region`) and `SPC o b` (`terminal-send-buffer`): the selection or line, or the buffer, goes to the project's terminal as a bracketed paste (or typed, for a program that didn't ask for it), a final line break dropped, then `<ret>` unless `terminal-send-enter` is off; the terminal is started if need be, and text for a new one waits for its first output; its window comes up and you stay in your buffer, a line sent from normal state moving the cursor down and visual mode ending. Tests, and a section in the terminals reference page.
- [ ] The `gz` operator: `gz{motion}` and text objects, `gzz` for the line, `gz` in visual mode, and `.` repeating it, all through `terminal-send-region`'s sending. Tests, and the page.
- [ ] Claude's sends paste with `terminal-paste!` (no `<ret>`, Claude's window focused, its waiting kept); `tests/claude.rs` passes unchanged. The Claude spec says so.
