---
type: Effort
status: active
issue: https://github.com/apisandipas/imp/issues/59
specs: ["[[spec/org-agenda]]", "[[spec/org]]"]
frozen:
  docs/specs/org-agenda.md: d283f91acd0d
  docs/specs/org.md: eacefd3dbd04
---
# Org agenda: clocking, logging, log mode and the clock report

## Approach

The fifth of six efforts for issue #59 ([[org-agenda]], [[org]]): clocking and logging in Org buffers, the agenda's clock keys, log mode and the clock report. Efforts 4–6 are built in parallel and shipped as one PR, at the owner's request.

Clocking writes `CLOCK:` lines in the heading's `:LOGBOOK:` drawer; the running clock is a global (file, heading text) found again by heading, so edits above it don't lose it, and an open `CLOCK:` line in an agenda file is picked up on start. Logging adds `CLOSED:` and, on a repeat, `LAST_REPEAT` and a state line, inside the same undo group as the keyword change. Log mode and the clock report read these lines from the agenda entries' text. Each task updates the reference pages in the same commit; tests go in `crates/imp-server/tests/org_clock.rs`.

## Tasks

- [x] Logging: `CLOSED:` on done (removed when undone), and on a repeat `LAST_REPEAT` and the `- State "DONE" from "TODO" [...]` logbook line (`org-log-done`, `org-log-repeat`); with tests
- [x] Clocking in Org buffers: clock in, out, cancel, go to (`C-c C-x C-i/C-o/C-q/C-j`, `SPC m c i/o/c/g`), one clock at a time, the status line's `[0:23/1:00] Title`, and a running clock picked up when imp starts; with tests
- [x] The agenda's `I`, `O`, `cc`, `cg`; with tests
- [ ] Log mode (`gD l`): `Closed`, `State` and `Clocked (1:15)` lines on each day at their times, done entries included; with tests
- [ ] The clock report (`gD R`, `cr`): a table of time per file and per heading two levels deep, with totals, in the clock report face (every bundled theme, Modus included); with tests
- [ ] Read the reference pages through against the specs and the keys, and check the which-key labels
- [ ] The owner has looked at it
