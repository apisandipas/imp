---
type: Effort
status: active
specs: ["[[spec/crash-recovery]]", "[[spec/files]]"]
issue: https://github.com/apisandipas/imp/issues/130
frozen:
  docs/specs/crash-recovery.md: 0b2c12382250
  docs/specs/files.md: f5ab70444dcc
---
# Crash recovery

Unsaved changes survive a crash ([[spec/crash-recovery]]). `runtime/files.scm` already copies modified file buffers into the state directory every `autosave-interval` seconds and has `:recover`, but writes the copies `0644` in a `0755` directory, doesn't say which imp wrote them, skips unnamed buffers, and offers a copy with a message rather than a prompt.

## Approach

Rust gets four small primitives and nothing else: `write-private-file!` (in `api/system.rs`, its work in `imp_core::fileio` beside the safe save, `create_new` with the mode set at creation as #129 does), `process-id`, `imp-running?` and `input-idle-ms`, the milliseconds since the last key, paste or mouse event from any client, which `Server::handle` stamps. Everything else is Scheme in `runtime/files.scm`.

Timing is a check every two seconds, on the timer that already checks for outside changes, rather than a timer re-armed on every key (a second timer out of step with that one would keep tests that pump events until a quiet spell from ever finishing): it compares each candidate buffer's `buffer-version` with the version last copied, notes when a buffer's first uncopied change was seen, and writes when input has been idle for `autosave-idle` or the change is `autosave-interval` old. It reads both options each time, so changing them needs no restart, and a buffer whose version hasn't moved costs a comparison, no write. The same check deletes the copy of a buffer that went back to unmodified (`:e!`, a reload, undo to the saved text). Two seconds' granularity is well inside the spec's 4 and 30.

A copy's owner is the `#PID` in its name; a copy is in use when that PID is this process or a running imp, and `copy-owner-alive?` is the one Scheme function that decides, so a test can fake another live imp by redefining it. The open prompt runs from the `buffer-open` hook, which fires the first time a buffer is shown. `:qa!` (and `:q!` on the last window) reaches the cleanup through a new `quit-discarding` hook that `quit-if-saved!` in `vim.scm` runs when `!` ends a standalone imp; in a daemon `:qa!` only detaches the client, so it keeps the copies, which are still in use.

## Tasks

- [x] `write-private-file!`: `fileio::write_private` writes atomically with the file born `0600` and its directory created `0700`, tightened to `0700` when it is the user's and looser; autosave writes through it, so copies are no longer `0644` in a `0755` directory. Unit tests in `fileio.rs`, a server test that a copy and its directory are private.
- [x] `process-id`, `imp-running?` (Linux `/proc/PID/comm`, `kill(PID, 0)` elsewhere) and `input-idle-ms` (stamped on every key, paste and mouse event), with tests.
- [x] Autosave timing and naming: copies named as the spec says (`%home%me%notes.org#4242`, `unnamed-N#PID`); the two-second check writes a changed buffer once input is `autosave-idle` seconds idle (new option, 4) or its first uncopied change is `autosave-interval` old, never rewrites an unchanged one; unnamed ordinary text buffers are copied; a name over 255 bytes or a failed write is said once per buffer. Key-driven tests; spec, files spec and both ref pages updated.
- [ ] Orphaned copies and the open prompt: when a buffer is first shown, a copy whose PID isn't alive is offered with `r`/`d`/`k` (same text deleted silently; a newer file noted; old-form names count as orphaned); `r` recovers as one undoable change and renames the copy to this process; another live imp's copy gives the "also being edited" warning once. Tests simulate a crash with a copy under a dead PID.
- [ ] `:recover` on the newest orphaned copy, `:recover FILE`, and `M-x recover-session` (a picker, newest first; unnamed copies open in a new buffer). Tests.
- [ ] Cleanup: the copy goes on save, on going back to unmodified, on kill (and an unnamed buffer emptied), on `:qa!`/`:q!` ending a standalone imp, and moves with `rename-file`; `:kill-server` and a daemon client's `:qa!` keep copies. Tests; the ref page loses "Not yet in imp" and the spec its known gap.
