---
type: Effort
status: planned
specs: ["[[spec/terminals]]"]
issue: https://github.com/apisandipas/imp/issues/87
frozen:
  docs/specs/terminals.md: f76ff705d85f
---
# Following the shell's directory and title

## Approach

vt100 already parses the sequences: OSC 0 and 2 reach `Callbacks::set_window_title`, and OSC 7 reaches `unhandled_osc`. `term.rs` gives its parser a callbacks struct that keeps the last title and the last local directory (the `file://` URL's host checked against this machine's with `gethostname`, the path percent-decoded), read from Scheme as `term-title` and `term-directory`. `term.scm` copies them into the terminal buffer's locals when it redraws, so they outlive the program. A `buffer-directory` function then answers "where is this buffer" (a terminal's directory, a browser's listing, a file's directory), and the commands the spec names use it. The title shows through a per-buffer status value, `%{title}`, in the default status line.

## Tasks

- [ ] The directory: `term-directory` from OSC 7 (local hosts only, percent-decoded), kept in the buffer as `term-dir` from the start directory on and after exit; `buffer-directory`; `find-file`, `:e NAME` and its completion, `-`, `:terminal`/`SPC o T` and the project use it from a terminal, a toggled terminal staying its own project's. Tests with a stand-in that prints OSC 7, and the reference page with the bash and zsh lines.
- [ ] The title: `term-title` from OSC 0 and 2, kept in the buffer and shown dimmed after its name in the status line (`%{title}`) and beside it in `switch-buffer`; an empty title clears it; it stays after exit. Tests, and the page.
