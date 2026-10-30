---
status: accepted
issue: https://github.com/apisandipas/imp/issues/16
summary: "Programs on a pty in a buffer, in a TERMINAL state, following the shell's directory and the program's title and kept from being killed by accident, and shells per project toggled in a popup, which text can be sent to."
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

### Following the program

- **Its directory (OSC 7).** A terminal buffer has a directory: the one it started in, until the shell reports another with OSC 7 (`ESC ] 7 ; file://HOST/PATH`, the path percent-decoded). From a terminal buffer, `find-file` lists the files of its directory's project, or under the directory outside one, `:e NAME` opens a relative `NAME` from there (its completion lists there too), `:Ex` (the file browser) lists it, `:terminal` and `SPC o T` start in it, and the project is that directory's, except that a toggled terminal stays its own project's, so `SPC o t` inside it still hides it. The directory stays after the program exits.
- **Only this machine's.** A report naming another host (a shell over `ssh` that sends OSC 7) is ignored, keeping the last directory; an empty host, `localhost`, or this machine's host name counts as this machine.
- **Shells that don't send it.** Without OSC 7 the directory stays where the terminal started. imp doesn't change your shell's setup; its reference page gives the lines for bash and zsh, which don't send it by default.
- **Its title (OSC 0 and 2).** When the program sets a title, it shows after the buffer's name in the status line, dimmed, and beside the name in `switch-buffer`'s list. The buffer's name doesn't change, so popup rules and toggles keep finding it, and two terminals with the same title are told apart by their names. An empty title clears it; after the program exits, its last title stays.

### Prompts

- **Marks (OSC 133).** When the shell marks its prompts with OSC 133 (`A` where a prompt starts, `B` where the command you type starts, `C` where its output starts, `D;N` when it finishes with status `N`), the terminal remembers each command's prompt line and output lines. A mark goes when its line scrolls out of the history.
- **Moving.** `]]` and `[[` go to the next and previous prompt, with a count and after operators; they move nowhere in other buffers, or in a terminal without marks.
- **One command's output.** `io` is the output of the command the cursor is in (its prompt, command or output lines), as whole lines: `yio` yanks it, `gzio` sends it on. `ao` is the prompt and command with it. Output still being printed counts up to the last line.
- **Signs.** Each prompt line has a sign in the sign column: `›`, or `✗` in the error face after a command that finished with a status other than 0.
- **Shells that don't mark.** Without OSC 133 nothing changes. imp doesn't change your shell's setup; the reference page gives the lines for bash and zsh.

### The clipboard (OSC 52)

- **Copying.** When a program in a terminal (`nvim`, `tmux`, a shell over `ssh`) copies text with OSC 52, imp puts it in the `"+` register as `"+y` does: on the system clipboard, through the same tools, and in the unnamed register, so `p` pastes it. The message line says "copied N characters from NAME". The primary selection (`p` in the sequence) goes to `"*` instead; anything else (`c`, `s`, digits, or none) is the clipboard.
- **Whose clipboard.** The `"+` register's: the machine imp runs on, so with `--via` the server's, as for a yank.
- **Reading is refused.** A request to read the clipboard (`?` in place of the text) gets no answer, so a program in a terminal can't see what you copied elsewhere.
- **Turning it off.** `(set-option! 'terminal-clipboard #f)` ignores OSC 52 from every terminal.

### Managing terminals

- **Killing a running one asks.** A terminal whose program is still running is treated as a buffer with unsaved changes. `:bd` refuses it ("a program is running in it (add ! to kill it)"), and `:bd!` kills it. `kill-buffer` (`SPC b d`, `SPC b k`, `C-x k`) asks "kill the program running in NAME? (y or n)" first. A terminal whose program has exited is killed without asking. `SPC a k` stops Claude without asking, as it's a command to stop it.
- **Quitting asks too.** `:q` (in the last window), `:qa`, `:wq`, `:x`, and `C-x C-c` refuse while a terminal is running, go to it, and say "a program is running in NAME (add ! to quit anyway)". `!` forms quit anyway. In a daemon, `:q` detaches the client and its terminals keep running, so it doesn't ask; `kill-server`, which stops them, asks y or n.
- **Turning it off.** `(set-option! 'terminal-confirm-kill #f)` kills and quits without asking. A terminal's buffer can turn it off for itself with `set-local-option!`.
- **A picker.** `switch-terminal` (`SPC o l`) lists the terminals: the buffer's name, then dimmed its command (or `shell`), its directory, and `exited` once its program has. Picking one shows it, in its popup window for a toggled terminal, else in the current window, and starts the TERMINAL state if it's running.
- **`:terminal ++name=NAME ++cwd=DIR CMD`.** `++name=` names the buffer `NAME` instead of `*terminal N*`; `++cwd=DIR` starts it in `DIR` (`~` and relative paths taken from the current buffer's directory) instead. Both can come before the command, in either order; without a command it runs your shell. A name that's taken gets `<2>`, `<3>` after it.
- **More than one per project.** A count picks which of a project's terminals `SPC o t` shows: `2 SPC o t` the second, started if need be, named `*terminal: PROJECT<2>*`. Without a count it shows the one last shown in that project (the first, to begin with), so `` M-` `` and `SPC o s` go to the one you were using. From inside any of them, `SPC o t` hides it. Toggles of your own (`define-toggled-terminal!`) take a count the same way.
- **Daemons.** A daemon's terminals belong to the server: they keep running when the last client detaches, and are there for the next client.

## Keys and options

- `SPC o t`, `M-\``: `toggle-terminal`. `SPC o T`: `terminal`.
- `SPC o s`: `terminal-send-region`. `SPC o b`: `terminal-send-buffer`. `gz`: the send operator.
- `terminal-send-enter` (on): whether sending presses `<ret>` after the text.
- `SPC o l`: `switch-terminal`.
- `]]`, `[[`: next and previous prompt. `io`, `ao`: a command's output, and with its prompt.
- `terminal-clipboard` (on): whether programs in terminals can copy to the clipboard.
- `terminal-confirm-kill` (on): whether killing or quitting with a running terminal asks.
- `define-toggled-terminal!`.

## Out of scope

- A toggled terminal that follows the current file's directory rather than the project's.
- Sending to a terminal other than the project's last-shown one (choosing one to send to), and sending to your own toggles (`lazygit`).
- Naming a toggled terminal, renaming a terminal buffer, and saving terminals across restarts.
- Language-aware sending (a whole function, a cell between `# %%` markers), and adapting text for a particular REPL (IPython's `%cpaste`).
- Middle-click pasting the primary selection in the window client.
- Mouse movement without a button held (any-motion reporting), which the clients don't send.
- Finding the directory without OSC 7 (reading the shell's from `/proc`), or setting it up in your shell for you.
- Opening files on the other host of an `ssh` session, and the icon name (OSC 1).
- Re-running a marked command, folding outputs, and showing a command's duration.
- Programs reading the clipboard through OSC 52, and copying to the client's machine rather than the server's with `--via`.
- Setting the outer terminal's or the window client's title from a terminal's.
