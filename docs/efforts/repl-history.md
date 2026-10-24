---
type: Effort
status: active
specs: ["[[spec/live-scheme-and-help]]"]
issue: https://github.com/apisandipas/imp/issues/14
frozen:
  docs/specs/live-scheme-and-help.md: 6f815da72533
---
# REPL history

Input history in the `*scheme*` REPL: `M-p`/`M-n`, `<up>`/`<down>` at the prompt, kept across sessions.

## Approach

The REPL moves from `modes.scm` to its own `runtime/repl.scm`, loaded after `files.scm`, because history needs `imp-state-dir` and `text-lines`, which later files define. History follows the command line's in `vim.scm` (newest first, prefix matching, earlier copies dropped, 200 entries) so the two behave alike. It is saved after each input to `repl-history` in the state directory, one entry per line with `\` and newlines escaped, as recent files are; failures to read or write are ignored.

Decisions made while the owner was away (issue #14 had no answers yet): `<up>`/`<down>` step history only on the last prompt's line in insert state, so multi-line input stays editable and normal-state `j`/`k` are untouched; prefix matching as on the command line; 200 entries with no option, as on the command line; no history search.

## Tasks

- [x] Move the REPL into `runtime/repl.scm`, loaded after `files.scm`, with the tests and help unchanged.
- [x] `M-p`/`M-n` in insert and normal state step through inputs typed this session, with prefix matching and the typed text restored past the newest; `<up>`/`<down>` do the same in insert state on the last prompt's line only. Tested in `eval.rs` or a new `repl.rs`.
- [ ] History is saved to `repl-history` in the state directory after each input and read when the REPL first needs it, multi-line inputs intact, 200 kept; an unwritable directory is ignored. Tested with a temporary state directory.
- [ ] Docs: `runtime/CONTEXT.md` load order lists `repl`, and the README mentions REPL history if it describes the REPL.
