---
status: accepted
issue: https://github.com/apisandipas/imp/issues/16
summary: "Programs on a pty in a buffer, in a TERMINAL state."
anchors: [runtime/term.scm, runtime/mouse.scm, crates/imp-server/src/term.rs, crates/imp-server/tests/term.rs, crates/imp-gui/src/keys.rs]
---
# Terminals

## Behaviour

- `:terminal [CMD]` (`SPC o t`) runs a program on a pty (portable-pty, vt100). The buffer holds the history (up to 10,000 lines) and the screen as text, with the program's colors on a per-buffer layer; ANSI colors 0-15 come from the theme.
- Output redraws at most every 15 ms, changing only the text that differs.
- In the TERMINAL state every key goes to the program, `<esc>` and `:` included. `C-\ C-n` leaves for normal state, where the text can be searched and yanked; `i a I A` return. `define-terminal-key!` keeps a key for the editor.
- Each terminal is sized to the windows showing it, the smallest rows and columns among them as in Neovim, and resized after any command that changes them as well as on output. A terminal no window shows keeps its size.
- **Mouse**: when the program asks for mouse reporting (`less`, `htop`, `vim`), clicks, releases, drags and the wheel in its window in the TERMINAL state go to it, in the encoding it asked for (SGR or the classic one), counted from its screen's corner. In other states, or when it didn't ask, the mouse does what it does in any buffer.
- **Paste**: the terminal client turns on bracketed paste, so a paste arrives whole. The window client (`imp --gui`) pastes the system clipboard on `S-<insert>` and `C-S-v` (`Cmd-v` on macOS), read with the same tools as the `"+` register; if none gives text, nothing is pasted and a message says so. `C-v` keeps its Vim meanings in both clients. In the TERMINAL state it goes to the program, between `ESC [200~` and `ESC [201~` when the program asked for that. In insert state it is inserted as it is, with no autoindent; in normal and visual state it is inserted at the cursor as one change; on the command line it is typed there, with line breaks as spaces.
- When the program exits, `[process exited N]` comes last and the buffer stays.

## Out of scope

- Middle-click pasting the primary selection in the window client.
- Mouse movement without a button held (any-motion reporting), which the clients don't send.
