---
type: Effort
status: done
specs: ["[[spec/terminals]]", "[[spec/leader-and-modes]]"]
issue: https://github.com/apisandipas/imp/issues/90
frozen:
  docs/specs/terminals.md: 3f2bd7f48634
  docs/specs/leader-and-modes.md: 9d5b35157001
---
# Managing terminals

## Approach

A running terminal is treated like a modified buffer: `running-terminals` lists the buffers whose program is still running (when `terminal-confirm-kill` is on for them), and the places that refuse or ask for unsaved changes (`:bd`, `kill-buffer`, `quit-if-saved!`, `kill-server`) check it too. A `daemon?` builtin tells Scheme when `:q` only detaches. The picker is a `completing-read` over the terminal buffers, annotated like M-x's commands. `:terminal` reads `++name=` and `++cwd=` before its command, as Vim's reads `++` options. A toggled terminal's table goes from project root to buffer to (root, n) to buffer, with the last-shown n kept per toggle and project, so a count picks one and no count brings back the last.

## Tasks

- [x] Asking before a kill: `:bd` refuses a running terminal and `:bd!` kills it; `kill-buffer` asks y or n; `:q`, `:qa`, `:wq`, `:x` (and `C-x C-c`) refuse, go to it and say so, `!` forms quitting anyway; in a daemon `:q` doesn't ask and `kill-server` does; `terminal-confirm-kill`, global or buffer-local, turns it off; an exited terminal and `SPC a k` don't ask. Tests, and the reference page.
- [x] `switch-terminal` (`SPC o l`): the terminals with command, directory and `exited` beside each; picking one shows it (a toggled one in its popup window) in the TERMINAL state if it's running. Tests, and the page.
- [x] `:terminal ++name=NAME ++cwd=DIR CMD`, in either order, a taken name getting `<2>`; `~` and relative directories from the current buffer's. Tests, and the page.
- [x] A count for toggled terminals: `2 SPC o t` shows the project's second (`*terminal: PROJECT<2>*`), no count the last shown, which `M-\`` and `SPC o s` use too; your own toggles the same. Tests, and the page.
