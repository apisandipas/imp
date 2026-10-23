---
status: accepted
summary: "Programs on a pty in a buffer, in a TERMINAL state."
anchors: [runtime/term.scm, crates/imp-server/src/term.rs, crates/imp-server/tests/term.rs]
---
# Terminals

## Behaviour

- `:terminal [CMD]` (`SPC o t`) runs a program on a pty (portable-pty, vt100). The buffer holds the history (up to 10,000 lines) and the screen as text, with the program's colors on a per-buffer layer; ANSI colors 0-15 come from the theme.
- Output redraws at most every 15 ms, changing only the text that differs.
- In the TERMINAL state every key goes to the program, `<esc>` and `:` included. `C-\ C-n` leaves for normal state, where the text can be searched and yanked; `i a I A` return. `define-terminal-key!` keeps a key for the editor.
- When the program exits, `[process exited N]` comes last and the buffer stays.

## Known gaps

- Only the current window's terminal resizes to fit. [#16](https://github.com/apisandipas/imp/issues/16)
- Mouse events and bracketed paste aren't passed to the program. [#16](https://github.com/apisandipas/imp/issues/16)
