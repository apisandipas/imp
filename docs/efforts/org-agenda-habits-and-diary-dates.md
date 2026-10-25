---
type: Effort
status: active
issue: https://github.com/apisandipas/imp/issues/59
specs: ["[[spec/org-agenda]]", "[[spec/org]]"]
frozen:
  docs/specs/org-agenda.md: b6ab81427154
  docs/specs/org.md: eacefd3dbd04
---
# Org agenda: habits and diary dates

## Approach

The last of six efforts for issue #59 ([[org-agenda]]): habits and diary dates. Efforts 4–6 are built in parallel and shipped as one PR, at the owner's request.

Diary dates are parsed from `<%%(...)>` timestamps into a predicate over dates, without running Lisp, and occur like any appointment; unknown sexps are counted and reported on the agenda's last line. A habit is an entry with `STYLE: habit` and a repeating `SCHEDULED`; its graph is drawn after the title from the done days in its logbook state lines and `LAST_REPEAT`, using Org's colors as faces. Each task updates the reference page in the same commit; tests go in `crates/imp-server/tests/org_agenda_habits.rs`.

## Tasks

- [x] Diary dates: `diary-anniversary` (with `%d`), `diary-float`, `diary-block`, `diary-cyclic`, `diary-date`, in `calendar-date-style` order; other sexps skipped and counted on the last line; with tests
- [x] Habits: on today only, never in `Overdue` or `Later`, with the graph (`org-habit-preceding-days`, `org-habit-following-days`; Org's four colors, `*` done, `!` today) in habit faces every bundled theme sets, Modus included; with tests
- [x] Read the reference page through against the spec, and check the agenda against the whole spec before #59 closes
- [ ] The owner has looked at it
