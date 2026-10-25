---
type: Page
spec: "[[spec/org-agenda]]"
frozen:
  docs/specs/org-agenda.md: a347b01704fc
---
# Org agenda

The agenda gathers what's scheduled, due and still to do in your Org files into one week, so you can see what's next without opening each file.

## Not yet in imp

- The agenda is being rebuilt to match Org's: appointments and times, a time grid, deadline warnings, tags, day to year views, a dispatcher with TODO lists, tag matches and search, changing tasks from the agenda, filters, bulk actions, clocking, habits and diary dates. [#59](https://github.com/apisandipas/imp/issues/59)

## Opening the agenda

`SPC o a` opens the agenda: this week's TODOs and dates from your agenda files, one day at a time.

- **Overdue**, at the top, lists undone tasks dated before today.
- **Each day** lists the tasks scheduled or due that day. A repeating task shows on every day it falls on, and today is marked.
- **Later** lists undone tasks dated after this week.
- **To do**, at the bottom, lists TODOs with no date.

Done tasks are left out. Tasks on the same day are sorted by priority. A file you have open is read from its buffer, so changes you haven't saved yet show too.

| Key | What it does |
|---|---|
| `<ret>` | Go to the task |
| `f` / `b` | Next or previous week |
| `.` | Back to this week |
| `gr` | Read the files again |

## Choosing the files

Set the files to read in `init.scm`. Relative names are looked up in `org-directory`. With none set, the agenda reads every `.org` file in `org-directory`.

```scheme
(set-option! 'org-agenda-files '("inbox.org" "work.org"))
```

## Options

| Option | Default | What it does |
|---|---|---|
| `org-agenda-files` | `'()` | The files the agenda reads; empty means every `.org` file in `org-directory` |
| `org-directory` | `"~/org"` | Where your Org files live |
| `org-agenda-span` | `7` | How many days the agenda shows |
| `calendar-week-start` | `0` | The day the agenda's week starts on: 0 is Sunday |
