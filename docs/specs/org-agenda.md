---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/59
anchors: [runtime/org-agenda.scm, crates/imp-server/tests/org_agenda.rs]
summary: "The Org agenda: Org's agenda views (day to year, TODO lists, tag and property matches, search, custom and block views) from a dispatcher, in aligned columns with a time grid, deadline warnings, habits and diary dates, acting on entries, filters, bulk actions, log mode and the clock report, with Doom's keys."
---
# Org agenda

The agenda gathers what's scheduled, due, timed and to do in the agenda files into one buffer, as Org's agenda does, and lets you act on it without leaving. It is laid out in aligned columns so it reads at a glance, and uses Doom's evil-org-agenda keys. It's part of Org mode ([[org]]); clocking, logging, tags, refile and archive in Org buffers are there too.

## Behaviour

### What it reads

- TODOs and dates from `org-agenda-files` (relative ones under `org-directory`); when that is empty, every `.org` file under `org-directory`. A file open in a buffer is read from the buffer, unsaved changes included, not from the disk.
- An entry's dates are its `SCHEDULED:` and `DEADLINE:` timestamps, and its plain active timestamps (`<2026-10-25 Sat 10:00>`), in the heading or the entry's text, which are appointments. Inactive timestamps (`[...]`) aren't dates, except in log mode.
- A timestamp's time (`10:00`, or a time range `10:00-11:00`) puts the entry at that time of day. A date range (`<2026-10-23 Fri>--<2026-10-25 Sun>`) is an appointment on each day it spans.
- **Diary dates**: a timestamp holding one of the common diary forms is an appointment on each day it gives, read without running Lisp. Month, day and year are in `calendar-date-style` order (`american` by default: month day year, as Emacs):
  - `<%%(diary-anniversary 10 25 1990)>`: every year on that day; `%d` in the title becomes the count of years.
  - `<%%(diary-float 11 4 4)>`: the 4th Thursday of November; a month of `t` is every month, and a negative count counts from the month's end.
  - `<%%(diary-block 10 20 2026 10 24 2026)>`: each day from the first date to the second.
  - `<%%(diary-cyclic 14 10 25 2026)>`: every 14 days from that date.
  - `<%%(diary-date 12 t 2026)>`: dates matching, `t` for any month, day or year.
  - Any other sexp is skipped, and the agenda's last line says how many were.
- An entry's tags are its own, those of the headings above it, and the file's `#+FILETAGS:`, as in Org.
- Done entries (a done keyword of `org-todo-keywords`) are left out of the dated views and the TODO list. A repeating timestamp falls on its date and each interval after it.

### Layout

- A title: the view's name (`Agenda`, `To do`, `Tags: +work`, …) on a line of its own, and under it what it covers, such as `Week 43 · 19–25 Oct 2026` (the ISO week most of its days are in, given for a week view), with any filters at the right, as `Filter: +work -home`. A rule across the window below them. (The name has its own line because the window client draws it larger, and a daemon may show the agenda in a terminal and a window at once.)
- Then the view's sections, each a header with a short rule under it. A section with nothing in it is left out, except a dated view's days.
- Each entry is one line, in columns that line up down the agenda: a mark column (bulk marks); its time; what the date is (`Sched.`, `Deadline`, and the counts below); its TODO keyword; its priority and title, with a habit's graph after it; its tags, right-aligned; its category (as in [[org]]), last. A column with nothing in it is blank, so the next stays aligned. The title is cut short with `…` so the tags and category stay in place; under 60 columns wide, tags are left out.
- In the window client, the title is drawn at a level-1 heading's size and each section and day header at a level-2's (`org-heading-heights`); terminals draw them at the text's size.
- Each part has its own face (title, dates, today, weekends, rules, times, grid, now line, scheduled, deadlines, overdue, coming deadlines, marks, tags, category, habit graph, clock report), which every bundled theme sets, Modus included.

### The dated view

- It shows a span of days. `SPC o a a` (`M-x org-agenda-list`) opens it as a week (`org-agenda-span`, 7 by default) from `org-agenda-start-on-weekday` (by default `calendar-week-start`'s day; `#f` starts on today). A span other than 7 or 14 days starts on today, as in Org.
- Days: each day's header is its date, as `Thursday 23 October`, weekends dimmer. Today's is marked with an accent bar at the left edge and `· today`. Every day of the span is shown, entries or not.
- `Overdue`, above the days when the span includes today, lists the undone entries scheduled or due before today, once each, oldest first: `Sched. 3x` for one scheduled 3 days ago, `2 d. ago` for a deadline 2 days past, in the overdue face. Appointments in the past aren't overdue.
- Under each day, its entries: timed ones first, by time, then the rest by priority (a heading without one counting as `B`).
- On today, deadlines coming within `org-deadline-warning-days` (14 by default; an entry's own warning, as `-3d` in its timestamp, wins) are listed too, as `In 2 d.`, in the coming-deadline face. On its own day a deadline shows as `Deadline`, in the deadline face.
- A date range shows on each of its days with its place in the range, `(2/3)`.
- `Later` lists the undone entries dated after the span, by date, once each (a repeating one at its next date after the span), each line starting with its date, so no open entry is hidden. `To do` lists the TODOs with no date.
- **Time grid**: today, and any other day with something timed, has a dim line at each of `org-agenda-time-grid`'s times (8:00 to 20:00 every two hours, by default), `08:00 ┄┄┄┄`, among the timed entries in order. A grid line at the same time as an entry is left out. On today, a `now` line, `11:42 ━━━ now ━━━`, sits in time order among them, at the time the agenda was drawn. `org-agenda-use-time-grid` (`#t`) turns the grid off and on.
- **Habits**: an entry whose `STYLE` property is `habit`, with a repeating `SCHEDULED` date, is a habit. It shows on today only, never in `Overdue` or `Later`, with a graph after its title: one cell per day for the `org-habit-preceding-days` (21) before today and `org-habit-following-days` (7) after. A cell is colored as Org's: blue before the habit is due, green while it is due, yellow on its last due day, red once it is overdue; a `*` marks a day it was done (from its logged state changes, see [[org]]), a `!` today.
- With no agenda files, a line says where it looked and how to set `org-directory` or `org-agenda-files`.

### Other views

- **The dispatcher**: `SPC o A` (`M-x org-agenda`) shows a menu of views, as Org's: `a` the dated view, `t` the TODO list, `T` the TODO list for one keyword (asked for), `m` a tags match, `M` a tags match of TODOs only, `s` a search, `n` the dated view and the TODO list together, and each custom command by its key. `<` first limits the next view to the current file, `< <` to the current subtree. `SPC o a` holds the common ones too: `SPC o a a` dated, `SPC o a t` TODO list, `SPC o a m` tags match, `SPC o a s` search.
- **The TODO list** lists every undone TODO entry in the agenda files, by priority, then in file order.
- **Tags match** asks for a match in Org's syntax and lists the headings it matches: tags joined by `+` (must have), `-` (must not), `&` and `|`, as `+work-urgent|home`; and comparisons of `TODO`, `LEVEL`, `PRIORITY`, `CATEGORY` and any property, with `=`, `<>`, `<`, `>`, `<=`, `>=` against a number, a `"string"` or a `{regexp}`, as `+work+Effort<"1:00"`. Tags include inherited ones; a property is the entry's own, and one it hasn't matches only `<>`; a `{regexp}` ignores case. Done entries are included; `M` leaves them out.
- **Search** asks for words and lists the entries whose heading or text holds them all, ignoring case: `+word` must be there, `-word` mustn't, `"a phrase"` as written, `{regexp}` a regexp.
- **Views of the dated view**: `gD` shows a menu, as Org's: `d` a day, `w` a week, `t` a fortnight, `m` a month (from its first day), `y` a year (from 1 January), `l` log mode, `R` the clock report, `g` the time grid. The view stays as chosen until the agenda is opened again.
- **Custom commands**: `(define-agenda-command! KEY DESCRIPTION BLOCKS)` adds a view to the dispatcher. Each block is `(agenda)`, `(todo)`, `(todo "NEXT")`, `(tags "MATCH")`, `(tags-todo "MATCH")` or `(search "WORDS")`, optionally with settings: `(agenda (span 1))`, `(tags-todo "+work" (header "Work"))`. Several blocks make a block agenda: each block's sections under its own header, one after another, in one buffer. Moving with `[[` and `]]` moves the dated blocks.

### Log mode and the clock report

- **Log mode** (`gD l`) adds to each day what happened on it: entries closed (`Closed`, from their `CLOSED:` stamp), state changes logged (`State`, as `DONE from TODO`), and time clocked (`Clocked`, with its length, as `(1:15)`), each at its time, done entries included.
- **The clock report** (`gD R`, or `cr`) adds a table below the view, as Org's clocktable: for the span, the time clocked on each file and on each heading under it, two levels deep, with each file's total and the total for all. It is drawn as an aligned table with rules, in the clock report face.

### Moving around

- The cursor starts on today's header when today is shown, else on the first line.
- `j` and `k` move a line, `gj` and `gk` (`C-j`, `C-k`) to the next and previous entry, `gH`, `gM` and `gL` to the window's top, middle and bottom.
- `[[` and `]]` (also `f` and `b`) move to the previous and next span; `.` goes back to today; `gd` asks for a date (the calendar) and goes to it.
- `<ret>` opens the entry's heading in the agenda's window; `<tab>` shows it in another window, keeping the cursor in the agenda. `SPC` stays the leader, as in Doom.
- `F` turns follow mode on and off: as the cursor moves, the entry under it shows in another window.
- `gr` reads the files again, and redraws the now line; `gR` redraws every agenda buffer. `ZZ` and `q` close the agenda, `ZQ` closes it and the buffers it opened.

### Acting on entries

- Each acts on the entry at the cursor, as the same command does in its Org buffer ([[org]]):
  - `t` cycles its TODO keyword, repeats and logging included; `SPC m t` picks one from a menu.
  - `SPC m d s` schedules it and `SPC m d d` gives it a deadline, from the calendar.
  - `H` and `L` move the date shown on the line a day earlier or later.
  - `+` and `-` raise and lower its priority; `SPC m p` sets it from a menu.
  - `ct` (`SPC m q`) sets its tags, completing from the agenda files' tags.
  - `ce` sets its effort (`Effort` property).
  - `SPC m r` refiles it under any agenda-file heading.
  - `da` archives it, asking first, and `dA` without asking (`org-archive-location`).
  - `dd` deletes the entry and its subtree, asking first.
  - `I` clocks in on it, `O` clocks out, `cc` cancels the clock, `cg` goes to the clocked entry.
  - `C` captures, with the line's date as the capture's date.
- A change edits the file's buffer, opening the file in the background if it isn't open, and saves it, unless the buffer had unsaved changes already, which then stay unsaved. The line redraws in place to show it; an entry no longer in the view (done, or moved off the span) goes.
- `u` undoes the last change made from the agenda, in its file's buffer, and redraws. A refile or archive into another file isn't undone, as undoing one file would leave the entry in both.

### Filters

- `sc` keeps only the entries in the category of the line at the cursor; `st` asks for a tag (completing) and keeps the entries with it, or with `-tag` without it; `se` asks for a comparison and an effort (`<1:00`) and keeps entries whose effort fits; `sr` asks for a regexp the title must match; `s^` keeps the entries under the cursor's entry's top-level heading.
- Filters add up, show in the title line, and stay through moving, redrawing and view changes until `S` removes them all. A section left empty by a filter is left out.

### Bulk actions

- `m` marks or unmarks the entry at the cursor, and moves down; `~` toggles every entry's mark, `*` marks all, `%` marks the entries whose title matches a regexp (asked for), `M` unmarks all. A marked line has a mark in its mark column and the marked face.
- `x` shows a menu of actions on the marked entries: `t` set a TODO keyword, `s` schedule, `d` deadline, `+` add a tag, `-` remove a tag, `r` refile, `$` archive, `S` move dates by a number of days (asked for), `k` delete. Each asks once for its value, then acts on each entry; the marks clear after.

## Keys and options

Opening: `SPC o A` (`M-x org-agenda`, `:OrgAgenda`) the dispatcher; `SPC o a a` (`M-x org-agenda-list`), `SPC o a t`, `SPC o a m`, `SPC o a s`.

In the agenda (normal state): `j` `k` `gj` `gk` `C-j` `C-k` `gH` `gM` `gL` `[[` `]]` `f` `b` `.` `gd` `<ret>` `<tab>` `F` `gr` `gR` `gD` `ZZ` `ZQ` `q`; `t` `H` `L` `+` `-` `ct` `ce` `da` `dA` `dd` `I` `O` `cc` `cg` `cr` `C` `u`; `sc` `st` `se` `sr` `s^` `S`; `m` `~` `*` `%` `M` `x`; under `SPC m`: `t`, `d s`, `d d`, `p`, `q`, `r`.

Options: `org-agenda-files`, `org-directory`, `org-agenda-span`, `org-agenda-start-on-weekday`, `org-deadline-warning-days`, `org-agenda-use-time-grid`, `org-agenda-time-grid`, `org-habit-preceding-days`, `org-habit-following-days`, `org-archive-location`, `calendar-week-start`, `calendar-date-style`, `org-heading-heights`.

## Out of scope

- Org's `org-agenda-prefix-format`, sorting and other layout options, and scheduled-ahead warnings.
- Emacs's diary file (`org-agenda-include-diary`), holidays, sunrise and moon phases, and sexps other than the five above.
- Clocktable dynamic blocks (`#+BEGIN: clocktable`) in Org files, clock resolving of idle time, and the clock's history.
- Column view in the agenda, `org-agenda-sticky`, stuck projects, and exporting or writing the agenda to a file.
- A now line that moves on its own, and drawing anything but text in the window client.
