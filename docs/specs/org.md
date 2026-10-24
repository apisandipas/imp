---
status: accepted
issue: https://github.com/apisandipas/imp/issues/44
summary: "Org mode: outlines, TODOs, checkboxes, links, tables, dates and repeaters, properties, agenda and capture."
anchors: [runtime/org.scm, runtime/calendar.scm, crates/imp-server/tests/org.rs, crates/imp-server/tests/capture.rs, crates/imp-server/tests/calendar.rs]
---
# Org

Org is the most common "why I can't leave Emacs", so `.org` files get a major mode covering what people rely on daily.

## Behaviour

- **Faces** by heading level, TODO keywords, dates, links, checkboxes, tables and markup, as per-buffer patterns that follow edits.
- **Outline**: `<tab>` cycles a subtree (folded, children, all), `<s-tab>` the buffer; `M-<ret>` adds a heading; promote, demote and move subtrees. Drawers (`:PROPERTIES:` … `:END:`) start closed and close again as headings cycle open; `<tab>` on one toggles it.
- **TODO and checkboxes**: TODO keywords cycle (`org-todo-keywords`), checkboxes toggle and update `[1/3]` cookies. `<ret>` does what the line means (link, checkbox, TODO, table), as in Doom Emacs.
- **Priorities**: a heading's `[#A]`, `[#B]` or `[#C]`, after its TODO keyword, is drawn in `org.priority`. `C-c ,` (`SPC m p`) sets it from a menu: `a`, `b`, `c`, or space to remove it. The agenda sorts entries on the same date, and the TODOs with no date, by priority, a heading without one counting as `B`, as in Org.
- **Links**: `[[target][text]]`; `<ret>` or `gx` follows one (a file, with `::LINE`, or a URL through `xdg-open`). Off the cursor's line a link shows just its description, as with org-appear.
- **Tables**: aligned, `|-` lines become rules, `<tab>` moves to the next cell. Typing in a cell in insert state keeps the table aligned as you go, the cursor staying in its cell; the cell keeps what was typed up to the cursor, spaces included, and the whole insert stays one undo step.
- **Dates**: a calendar above the command line (three months, arrows and PageUp/PageDown, or typed: `fri`, `+3d`, `11-03`, `tom 3pm`). `C-c C-s` and `C-c C-d` (`SPC m s`, `SPC m d`) set SCHEDULED and DEADLINE; `C-c .` puts or changes a timestamp.
- **Repeaters**: a timestamp may end in a repeater, `+1w`, `++1w` or `.+1w`, in days, weeks, months or years (`d w m y`), before any warning period such as `-3d`. Marking a heading done (a done keyword of `org-todo-keywords`) when its entry has a repeating active timestamp moves each one on by its interval instead and sets the keyword back to the first of `org-todo-keywords`. With `+` the date moves one interval. With `++` it moves by whole intervals until it is after today. With `.+` it moves to one interval after today. Each timestamp keeps its time, repeater and warning, and gets the right day name. A month added to the 31st lands on the month's last day. Changing a repeating timestamp from the calendar keeps its repeater.
- **Properties**: a heading's `:PROPERTIES:` drawer holds `:NAME: value` lines. `(org-entry-property line name)` gives the value of `name` for the heading `line` is under, ignoring case, or #f. With a third argument `#t` it looks up the heading's ancestors when it has none, then the file's `#+PROPERTY: NAME value` lines. `C-c C-x p` (`SPC m P`) sets a property on the heading, asking for the name (completing from the buffer's property names) and then the value; the drawer is made after the heading's planning line if it has none, and an empty value removes the property.
- **Category**: the agenda shows each entry's category in place of its file name: its `CATEGORY` property, inherited, or the file's `#+CATEGORY:` line, or else the file's name without `.org`.
- **Agenda** (`SPC o a`): TODOs and dates from `org-agenda-files` (relative ones under `org-directory`), as Org's week view. It shows `org-agenda-span` days (7 by default), from the first day of this week (`calendar-week-start`), each day under its own line and today's marked. Under each day are the undone entries scheduled or due that day. A repeating entry shows on each day it falls on, from its date onward. Above the days, `Overdue` lists the undone entries whose date is before today, once each. Below them, `To do` lists the TODOs with no date. Done entries are left out, and an entry dated after the span isn't shown. `f` and `b` move to the next and previous span, `.` back to this week, `gr` reads the files again, and `<ret>` jumps to an item.
- **Capture** (`SPC o c`): templates (`define-capture-template!`, targets `file`, `file+headline`, `file+datetree`, Org's `%` escapes, `%^t` and `%^u` asking for a date) in a `*capture*` buffer down the right. `C-c C-c` or `:w` files it, `C-c C-k` cancels, `C-c C-w` refiles under any agenda-file heading. An entry still as the template made it isn't filed. Filing goes through the file's buffer when open, else straight to the file.
- **Indent** (`org-indent-mode`, `SPC m i`): sections drawn indented under their headings, display only.
- **Heading heights** in the window client: `org-heading-heights` (default `'(1.4 1.25 1.1)`).
- Running source blocks is the `org-babel` package ([[packages]]).

## Keys and options

`org-directory`, `org-agenda-files`, `org-default-notes-file`, `org-todo-keywords`, `org-agenda-span`, `org-link-descriptive` (`SPC m l` toggles), `org-fold-drawers`, `org-indent`, `org-indent-per-level`, `org-heading-heights`.

## Known gaps

- No export. [#54](https://github.com/apisandipas/imp/issues/54)
- The agenda has no day or month view, and a deadline doesn't show before its day (no warning periods in the agenda). Repeating doesn't log the change (no `LAST_REPEAT` or state-change notes), the calendar can't add a repeater (type one into the timestamp), and there are no hourly repeaters.
- Properties aren't used beyond `CATEGORY`: no column view, no property searches in the agenda, and no special properties such as `ID` or `STYLE`.
