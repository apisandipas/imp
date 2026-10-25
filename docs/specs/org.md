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
- **Agenda** (`SPC o A`, `SPC o a a`): Org's agenda views, acting on entries from them, filters and bulk actions; see [[org-agenda]].
- **Tags**: `C-c C-q` (`SPC m q`) sets the heading's tags, as Doom's does: each tag picked, completing from the agenda files' tags (those it has marked), or a new one typed, is added, or removed if the heading has it, and it asks again until `<esc>`. They go after the title, as `:work:urgent:`, ending at column 77 (`org-tags-column`, as Org).
- **Effort**: `C-c C-x e` (`SPC m c E`) sets the heading's `Effort` property, as `0:45` or `1:30`.
- **Refile**: `C-c C-w` (`SPC m r`) moves the heading and its subtree under any agenda-file heading (asked for, as capture's refile), at the right level.
- **Archive**: `C-c C-x C-a` (`SPC m A`) moves the heading and its subtree to `org-archive-location` (`"%s_archive::"`, by default: the file's name with `_archive` added, at the top level), with Org's `ARCHIVE_TIME`, `ARCHIVE_FILE`, `ARCHIVE_OLPATH`, `ARCHIVE_CATEGORY` and `ARCHIVE_TODO` properties. The archive file is made if it doesn't exist and isn't read by the agenda.
- **Clocking**: `C-c C-x C-i` (`SPC m c i`) clocks in on the heading: a `CLOCK: [2026-10-25 Sat 11:42]` line in its `:LOGBOOK:` drawer, made after the planning line and properties if there is none. `C-c C-x C-o` (`SPC m c o`) clocks out, ending the line as `--[2026-10-25 Sat 12:57] =>  1:15`. One clock runs at a time; clocking in elsewhere clocks out the running one first. `C-c C-x C-q` (`SPC m c c`) cancels it, removing its line; `C-c C-x C-j` (`SPC m c g`) goes to the clocked heading. While it runs, the status line shows its time and title, as `[0:23/1:00] Write report` with the heading's effort, each minute. A clock left running in an agenda file (an open `CLOCK:` line) is picked up again when imp starts.
- **Logging**: marking a heading done adds `CLOSED: [2026-10-25 Sat 11:42]` to its planning line, and undoing it removes the stamp (`org-log-done`, `'time` by default, as Doom; `#f` turns it off). A repeat also sets the `LAST_REPEAT` property and adds `- State "DONE"       from "TODO"       [2026-10-25 Sat 11:42]` to the top of its `:LOGBOOK:` (`org-log-repeat`, `'time`). The agenda's log mode and habits read these ([[org-agenda]]).
- **Capture** (`SPC o c`): templates (`define-capture-template!`, targets `file`, `file+headline`, `file+datetree`, Org's `%` escapes, `%^t` and `%^u` asking for a date) in a `*capture*` buffer down the right. `C-c C-c` or `:w` files it, `C-c C-k` cancels, `C-c C-w` refiles under any agenda-file heading. An entry still as the template made it isn't filed. Filing goes through the file's buffer when open, else straight to the file.
- **Indent** (`org-indent-mode`, `SPC m i`): sections drawn indented under their headings, display only.
- **Heading heights** in the window client: `org-heading-heights` (default `'(1.4 1.25 1.1)`).
- Running source blocks is the `org-babel` package ([[packages]]).
- Export to HTML, PDF and other formats is the org-export package, through pandoc ([[org-export]]).

## Keys and options

`org-directory`, `org-agenda-files`, `org-default-notes-file`, `org-todo-keywords`, `org-archive-location`, `org-log-done`, `org-log-repeat`, `org-tags-column`, `org-link-descriptive` (`SPC m l` toggles), `org-fold-drawers`, `org-indent`, `org-indent-per-level`, `org-heading-heights`.

## Known gaps

- Changing a keyword doesn't ask for a note (`org-log-done 'note`), the calendar can't add a repeater (type one into the timestamp), and there are no hourly repeaters.
- Properties aren't used beyond `CATEGORY`, `Effort`, `STYLE` and the agenda's matches: no column view, and no special properties such as `ID`.
