---
type: Effort
status: done
specs: ["[[spec/org]]"]
issue: https://github.com/apisandipas/imp/issues/15
frozen:
  docs/specs/org.md: ab698bdd478c
---
# Org repeaters and properties

Repeating timestamps move on when their heading is marked done, and the agenda is a week view that shows them on each day they fall. Properties were planned here too, but the owner shipped without them; they stay on #15.

## Approach

All of it is Scheme in `runtime/org.scm`, with the date arithmetic `calendar.scm` already has. Timestamps are parsed into their parts (date, time, repeater, warning) once, so repeating, the calendar and the agenda share one reader rather than each slicing strings. The agenda becomes a week view, as Org's, so that a repeating entry can show on each day it falls on; the owner chose this over keeping the open-ended Upcoming list. Planned and built while the owner was away; the choices made are listed in the PR.

## Tasks

- [x] Parse a timestamp into date, time, repeater and warning, and write it back with its day name, with tests.
- [x] Marking a heading done moves on its entry's repeating active timestamps (`+`, `++`, `.+`) and sets its keyword back to the first TODO keyword, with tests.
- [x] Changing a repeating timestamp from the calendar keeps its repeater, with a test.
- [x] The agenda is a week view (`org-agenda-span` days from the week's first day, each day's entries under it, Overdue above and To do below), with `f`, `b` and `.`, and the existing agenda tests updated, with tests.
- [x] A repeating entry shows on each day it falls on in the agenda's span, with a test.
- [x] The file's header comment lists the agenda's keys and repeaters; the owner has tried them by hand.
