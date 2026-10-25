---
type: Page
spec: "[[spec/org-agenda]]"
frozen:
  docs/specs/org-agenda.md: d283f91acd0d
---
# Org agenda

The agenda gathers what's scheduled, due and still to do in your Org files into one week, so you can see what's next without opening each file.

## Not yet in imp

- More of Org's agenda is on its way: day to year views, filters, bulk actions, clocking, habits and diary dates. [#59](https://github.com/apisandipas/imp/issues/59)

## Opening the agenda

`SPC o a a` (or `M-x org-agenda-list`) opens the agenda on this week, with the cursor on today.

- **Overdue**, at the top, lists undone tasks scheduled or due before today. `Sched. 3x` means it was scheduled 3 days ago; `2 d. ago` means its deadline was 2 days ago.
- **Each day** lists what falls on it: scheduled tasks, deadlines and appointments. A repeating task shows on every day it falls on.
- **Later** lists undone tasks dated after this week, each with its date.
- **To do**, at the bottom, lists TODOs with no date.

Done tasks are left out. A file you have open is read from its buffer, so changes you haven't saved yet show too.

## Reading a line

Each task is one line, and its parts line up down the agenda:

```
    14:00   Sched.    TODO  [#A] Review the pull request    :work:  imp
```

From the left: its time, what the date is, its TODO keyword, its priority and title, its tags, and its category (see [Org](ref-org.md)). A long title is cut short with `…` so the rest stays in place. In a window under 60 columns wide, tags are left out.

In the window client, the agenda's title and the day headers are drawn larger, at the sizes `org-heading-heights` gives Org's headings.

## Times and appointments

A time in a task's date, such as `<2026-10-25 Sun 14:00>` or `<2026-10-25 Sun 9:30-10:00>`, puts it at that time of day. Timed tasks come first in their day, by time; the rest follow by priority.

Any other active date in a heading or its text is an appointment, shown on its day:

```org
* Dentist <2026-10-24 Sat 10:00>
* Conference
<2026-11-02 Mon>--<2026-11-04 Wed>
```

A date range shows on each of its days, as `(2/3)` on the second.

## The time grid

Today, and any other day with something timed, has a time grid: a dim line every two hours from 08:00 to 20:00, among the timed tasks. On today, a `now` line marks the time the agenda was drawn; `gr` moves it on.

```scheme
(set-option! 'org-agenda-use-time-grid #f)          ; no grid
(set-option! 'org-agenda-time-grid '(900 1200 1700)) ; other times
```

## Deadlines coming up

Deadlines in the next 14 days also show on today, as `In 3 d.`. A deadline can give its own warning period in its timestamp:

```org
DEADLINE: <2026-10-30 Fri -3d>
```

That one shows on today only from three days before.

## Tags

A task's tags are its own, those of the headings it's under, and the file's `#+FILETAGS:`:

```org
#+FILETAGS: :home:
* Garden :outside:
** TODO Plant the bulbs :autumn:
```

`Plant the bulbs` shows as `:autumn:outside:home:`.

## The dispatcher

`SPC o A` (or `M-x org-agenda`, or `:OrgAgenda`) shows a menu of views, as Org's agenda dispatcher does:

| Key | View |
|---|---|
| `a` | The agenda for the week |
| `t` | Every undone TODO |
| `T` | The TODOs with one keyword, asked for |
| `m` | Headings matching tags and properties |
| `M` | The same, undone TODOs only |
| `s` | A search |
| `n` | The week's agenda and every TODO, one after the other |
| `<` | Limit the next view to the file you're in; press it again for the heading the cursor is under and everything below it |

A limited view says so in its title, and keeps the limit when you press `gr`.

## Lists of TODOs

`SPC o a t` (or `M-x org-todo-list`) lists every undone TODO in your agenda files, dated or not, by priority and then in the order they're written. The same keys work on it as in the agenda, so you can change a task from the list.

## Matching tags and properties

`SPC o a m` (or `M-x org-tags-view`) asks for a match and lists every heading it fits, done ones too:

| Match | Finds headings |
|---|---|
| `work` | tagged `work`, or under a heading or file that is |
| `+work-urgent` | tagged `work` but not `urgent` |
| `work\|home` | tagged either |
| `{^pro}` | with a tag matching a regexp |
| `TODO="NEXT"` | with the keyword `NEXT` |
| `PRIORITY="A"` | with priority `A` |
| `LEVEL>1` | below the top level |
| `CATEGORY="work"` | in the category `work` |
| `+work+Effort<"1:00"` | tagged `work`, with an `Effort` property under `1:00` |

Compare properties with `=`, `<>`, `<`, `>`, `<=` or `>=`, against a number, a `"string"` or a `{regexp}`. A heading without the property matches only `<>`.

## Searching

`SPC o a s` (or `M-x org-search-view`) asks for words and lists every entry whose heading or text holds them all, ignoring case:

| Search | Finds entries |
|---|---|
| `bank loan` | with both words |
| `bank -holiday` | with `bank` but not `holiday` |
| `"the bank later"` | with that phrase |
| `{bulbs?}` | matching a regexp |

## Days, weeks, months

Press `gD` to change how much the agenda shows:

| Key | What it shows |
|---|---|
| `d` | The day the cursor is on |
| `w` | Its week |
| `t` | Its fortnight |
| `m` | Its month, from the 1st |
| `y` | Its year, from 1 January |
| `g` | Turn the time grid on or off |

`f` and `b` then move by that much: a month at a time in a month's view. The agenda is back to a week the next time you open it.

## Moving around

| Key | What it does |
|---|---|
| `gj` / `gk` | Next or previous task (also `C-j` / `C-k`) |
| `gH` / `gM` / `gL` | Top, middle or bottom of the window |
| `f` / `b` | Next or previous week (also `]]` / `[[`) |
| `.` | Back to today |
| `gd` | Go to a date, picked from the calendar |
| `<ret>` | Go to the task |
| `<tab>` | Show the task in another window, staying in the agenda |
| `F` | Follow mode: show each task the cursor moves to |
| `gr` | Read the files again |
| `gR` | Read the files again, in every agenda buffer |
| `q` / `ZZ` | Leave the agenda |
| `ZQ` | Leave the agenda and close the files it opened (not ones with unsaved changes) |

## Changing tasks from the agenda

Change a task right from its line, without opening its file.

| Key | What it does |
|---|---|
| `t` | Cycle its TODO keyword, as `<ret>` does on its heading |
| `SPC m t` | Pick its TODO keyword, or none |
| `SPC m d s` | Schedule it, picking the date from the calendar |
| `SPC m d d` | Give it a deadline, from the calendar |
| `H` / `L` | Move the date on the line a day earlier or later; `3L` is three days |
| `+` / `-` | Raise or lower its priority; a task without one counts as `B` |
| `SPC m p` | Set its priority: `a`, `b` or `c`, or space to remove it |
| `ct` or `SPC m q` | Add or remove tags, as `C-c C-q` does in its file |
| `ce` | Set its effort, such as `0:45` |
| `SPC m r` | Refile it under another heading, as `C-c C-w` does |
| `da` | Archive it, after asking |
| `dA` | Archive it without asking |
| `dd` | Delete it and everything under it, after asking |
| `C` | Capture a new task for the day the cursor is on |
| `u` | Undo the last change made from the agenda |

`H` and `L` move the date that line shows: its scheduled date, its deadline, or an appointment, keeping its time and repeater.

The change is made in the task's file. If the file isn't open, it's opened out of sight and saved. If it's open with changes you haven't saved, the change joins them and nothing is saved. The agenda redraws to show it; a task that's now done leaves the agenda. `u` can't undo refiling or archiving into another file.

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
| `org-agenda-start-on-weekday` | `calendar-week-start` | The day a week starts on, 0 (Sunday) to 6; `#f` starts on today. Spans other than a week or fortnight start on today |
| `org-deadline-warning-days` | `14` | How many days ahead deadlines show on today |
| `org-agenda-use-time-grid` | `#t` | Draw the time grid |
| `org-agenda-time-grid` | `'(800 1000 1200 1400 1600 1800 2000)` | The grid's times, `800` being 08:00 |
| `calendar-week-start` | `0` | The day weeks start on: 0 is Sunday |
