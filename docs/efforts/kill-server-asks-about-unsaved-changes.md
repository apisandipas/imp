---
type: Effort
status: done
specs: ["[[spec/daemon]]", "[[spec/commands]]", "[[spec/crash-recovery]]"]
issue: https://github.com/apisandipas/imp/issues/157
frozen:
  docs/specs/daemon.md: 9b8eb57051c7
  docs/specs/commands.md: 03eb47131286
  docs/specs/crash-recovery.md: 5c3612bb556d
---
# Kill server asks about unsaved changes

`:kill-server` stopped the daemon for every client and threw away unsaved changes without a word ([[spec/daemon]]). It now refuses like `:qa`, and `:kill-server!` stops anyway.

## Approach

`kill-server` is a command, not an ex command ([[0019-interactive-features-are-m-x-commands-ex-commands-are-vim-s]]), and `run-command-from-ex!` in `runtime/vim.scm` dropped the `!` it parsed. It now keeps it for the command to read with `command-bang?`, as it keeps the text after the name for `command-argument`; that is the general way for a command to take `!` ([[spec/commands]]), not a `define-ex! "kill-server"` beside Vim's own.

The command in `runtime/term.scm` checks `modified-buffers` first and goes to the first, then asks about running terminals as before; with `!` it calls `kill-server!` straight away. It doesn't run the `quit-discarding` hook, so the crash copies stay ([[spec/crash-recovery]]). The refusal's hint names `:kill-server!` rather than "add !", since it is also reached from M-x, where there is nothing to add `!` to.

Tests are key-driven, in `crates/imp-server/tests/crash_recovery.rs` and `terminal_manage.rs`, faking a daemon by redefining `daemon?` as those files already do.

## Tasks

- [x] `command-bang?` for commands run from `:NAME!`; `kill-server` refuses with unsaved changes, asks about terminals only after, and `:kill-server!` stops at once keeping copies. Tests; the daemon, commands and crash-recovery reference pages.
