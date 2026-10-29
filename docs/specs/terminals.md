---
status: accepted
issue: https://github.com/apisandipas/imp/issues/16
summary: "Programs on a pty in a buffer, in a TERMINAL state, and a shell per project toggled in a popup, which text can be sent to."
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
- `SPC o T` runs your shell in a new terminal buffer in the current window, as `:terminal` does.

### The project's terminal

- **One shell per project, toggled.** `toggle-terminal` (`SPC o t`, and `M-\`` in every state, TERMINAL included) shows the current project's shell, starting it the first time in the project root, and puts you in the TERMINAL state there. From inside it, the same key hides it, closing its window; the shell keeps running and comes back as it was. Outside any project, the terminal is imp's current directory's, one shared by every buffer outside a project.
- **Its window** is placed by a popup rule, `"*terminal:"` down the right at 40%, as Claude's is; `define-popup-rule!` moves it. Popups on the same side share one window, so showing the terminal while Claude is shown puts it in Claude's window, and Claude keeps running hidden.
- **After the shell exits** (you typed `exit`), the toggle replaces the dead buffer with a new shell in the project root.
- **The buffer** is named `*terminal: PROJECT*`, after the project root's directory, and is a terminal like any other: `C-\ C-n`, searching and yanking, and killing it stops the shell.
- **Your own.** `(define-toggled-terminal! NAME COMMAND PREFIX)` makes command `NAME` toggle a program the same way, one per project: `COMMAND` is what runs (`""` for your shell, or a symbol naming an option that holds it), and `PREFIX` starts its buffer's name, for its popup rule. `(define-toggled-terminal! 'lazygit "lazygit" "*lazygit")` gives `M-x lazygit`. Bind it with `define-leader!`, and with `define-terminal-key!` to hide it from inside.
- **Claude is one.** Claude's panel ([[spec/claude]]) is built on `define-toggled-terminal!`, with what it adds (sending text, waiting for its prompt) on top, and keeps its keys, buffer names and popup rule.

### Sending text to it

- **To the project's terminal.** `SPC o s` sends the selection in visual mode, or the current line in normal state, to the project's terminal; `SPC o b` sends the whole buffer; `gz{motion}` sends what the motion or text object covers (`gzap` a paragraph, `gzz` the line, `gz` in visual mode the selection), and `.` repeats it. The terminal is started first if it isn't running.
- **As a paste, then run.** The text goes as a bracketed paste when the program asked for that (shells do), and as typed otherwise, with a final line break dropped; then `<ret>` is sent so it runs, unless `terminal-send-enter` is off. Text sent to a shell that is just starting waits until it has printed something (its prompt), so it isn't lost.
- **You stay where you were.** The terminal's window comes up if it was hidden, and the cursor stays in your buffer; sending the line from normal state moves the cursor to the next line, so `SPC o s` again sends the one after. Visual mode ends after sending.
- **Claude's sends** (`SPC a s`, `SPC a b`, `SPC a f`) are built on the same sending, with `<ret>` never sent and you taken to Claude's window, as now.

## Keys and options

- `SPC o t`, `M-\``: `toggle-terminal`. `SPC o T`: `terminal`.
- `SPC o s`: `terminal-send-region`. `SPC o b`: `terminal-send-buffer`. `gz`: the send operator.
- `terminal-send-enter` (on): whether sending presses `<ret>` after the text.
- `define-toggled-terminal!`.

## Out of scope

- More than one toggled terminal per project (a count, names, a picker), and asking before killing a running one: #90.
- A toggled terminal that follows the current file's directory rather than the project's.
- Sending to a terminal other than the project's (a picker, or the last one used), and sending to your own toggles (`lazygit`): #90 or later.
- Language-aware sending (a whole function, a cell between `# %%` markers), and adapting text for a particular REPL (IPython's `%cpaste`).
- Middle-click pasting the primary selection in the window client.
- Mouse movement without a button held (any-motion reporting), which the clients don't send.
