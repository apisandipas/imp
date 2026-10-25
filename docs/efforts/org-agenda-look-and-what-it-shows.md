---
type: Effort
status: active
issue: https://github.com/apisandipas/imp/issues/59
specs: ["[[spec/org-agenda]]", "[[spec/org]]"]
frozen:
  docs/specs/org-agenda.md: 7188e85aaf98
  docs/specs/org.md: 2a4bc3dc93d6
---
# Org agenda: look and what it shows

## Approach

The first of six efforts for issue #59, all against [[org-agenda]]: this one covers *What it reads*, *Layout*, *The dated view* (without habits and diary dates, which are effort 6) and *Moving around*. The later efforts are acting on entries (with the Org-buffer commands in [[org]]), views and the dispatcher, filters and bulk actions, clocking and logging with log mode and the clock report, and habits with diary dates. This effort's PR doesn't close #59; the last one does.

The agenda code moves out of `runtime/org.scm`, which is already long, into its own file, `runtime/org-agenda.scm`, loaded after it. Reading comes first: an entry gets a list of dated *occurrences* (scheduled, deadline, appointment, range day), each with an optional time, plus its tags, read from a file's buffer when one is open. Rendering is then one function per section over those occurrences, and one function that lays an entry out in columns, sized to the window, so the later views reuse it. Faces are new `org.agenda.*` faces in `runtime/theme.scm`, set by every theme from its palette, and by the Modus package from Modus's own agenda faces. Larger headers use the same height faces as Org's headings.

The Ledger mockup the owner chose is the visual target. The work is checked against it with terminal captures and window-client screenshots before the last task.

## Tasks

- [x] Move the agenda into `runtime/org-agenda.scm` unchanged, and read an entry's timestamps (scheduled, deadline, appointments in the heading or text, times and time ranges, date ranges) and tags (own, inherited, `#+FILETAGS:`), from the file's buffer when it's open; with tests. Start the `ref-org-agenda` page with the agenda as it is, and point `ref-org`'s agenda section to it, each saying only what's built
- [x] Lay out an entry in columns (mark, time, what, keyword, title, tags, category), with the title cut by `…` and tags dropped under 60 columns; the title line with the week, section headers with rules, day headers with weekends dimmer and today's accent bar; new `org.agenda.*` faces in every theme; larger title and headers in the window client; with tests
- [x] The dated view's contents: `Overdue` with `Sched. 3x` and `2 d. ago`, timed entries first by time then by priority, deadline warnings on today (`org-deadline-warning-days`, an entry's `-3d`), ranges with `(2/3)`, `Later` lines starting with their date; with tests
- [x] The time grid and the `now` line (`org-agenda-time-grid`, `org-agenda-use-time-grid`), on today and on days with something timed; with tests
- [x] `org-agenda-start-on-weekday`, and the cursor starting on today's header; with tests
- [x] Moving around: `gj`/`gk` (`C-j`/`C-k`), `gH`/`gM`/`gL`, `[[`/`]]`, `gd`, `<tab>` in another window, follow mode (`F`), `gR`, `ZZ`/`q`, `ZQ`; with tests
- [x] The Modus themes' colors for the `org.agenda.*` faces, from Modus's agenda faces, with a test
- [x] The reference page `ref-org-agenda` covering this effort (and a line on what's to come), the agenda's keys in the help and the which-key labels
- [x] Compare terminal captures and window-client screenshots, in a dark and a light theme, with the Ledger mockup, and fix what differs
- [ ] The owner has looked at the agenda
