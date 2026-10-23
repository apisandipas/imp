---
status: accepted
summary: "Org mode: outlines, TODOs, checkboxes, links, tables, dates, agenda and capture."
anchors: [runtime/org.scm, runtime/calendar.scm, crates/imp-server/tests/org.rs, crates/imp-server/tests/capture.rs, crates/imp-server/tests/calendar.rs]
---
# Org

Org is the most common "why I can't leave Emacs", so `.org` files get a major mode covering what people rely on daily.

## Behaviour

- **Faces** by heading level, TODO keywords, dates, links, checkboxes, tables and markup, as per-buffer patterns that follow edits.
- **Outline**: `<tab>` cycles a subtree (folded, children, all), `<s-tab>` the buffer; `M-<ret>` adds a heading; promote, demote and move subtrees. Drawers (`:PROPERTIES:` … `:END:`) start closed and close again as headings cycle open; `<tab>` on one toggles it.
- **TODO and checkboxes**: TODO keywords cycle (`org-todo-keywords`), checkboxes toggle and update `[1/3]` cookies. `<ret>` does what the line means (link, checkbox, TODO, table), as in Doom Emacs.
- **Links**: `[[target][text]]`; `<ret>` or `gx` follows one (a file, with `::LINE`, or a URL through `xdg-open`). Off the cursor's line a link shows just its description, as with org-appear.
- **Tables**: aligned, `|-` lines become rules, `<tab>` moves to the next cell.
- **Dates**: a calendar above the command line (three months, arrows and PageUp/PageDown, or typed: `fri`, `+3d`, `11-03`, `tom 3pm`). `C-c C-s` and `C-c C-d` (`SPC m s`, `SPC m d`) set SCHEDULED and DEADLINE; `C-c .` puts or changes a timestamp.
- **Agenda** (`SPC o a`): TODOs and dates from `org-agenda-files` (relative ones under `org-directory`); `<ret>` jumps to an item.
- **Capture** (`SPC o c`): templates (`define-capture-template!`, targets `file`, `file+headline`, `file+datetree`, Org's `%` escapes, `%^t` and `%^u` asking for a date) in a `*capture*` buffer down the right. `C-c C-c` or `:w` files it, `C-c C-k` cancels, `C-c C-w` refiles under any agenda-file heading. An entry still as the template made it isn't filed. Filing goes through the file's buffer when open, else straight to the file.
- **Indent** (`org-indent-mode`, `SPC m i`): sections drawn indented under their headings, display only.
- **Heading heights** in the window client: `org-heading-heights` (default `'(1.4 1.25 1.1)`).
- Running source blocks is the `org-babel` package ([[packages]]).

## Keys and options

`org-directory`, `org-agenda-files`, `org-default-notes-file`, `org-todo-keywords`, `org-link-descriptive` (`SPC m l` toggles), `org-fold-drawers`, `org-indent`, `org-indent-per-level`, `org-heading-heights`.

## Known gaps

- No repeating timestamps, priorities or export, and properties aren't read. [#15](https://github.com/apisandipas/imp/issues/15)
- Typing in a table cell doesn't keep the table aligned; `<tab>` or `<ret>` realigns. [#15](https://github.com/apisandipas/imp/issues/15)
