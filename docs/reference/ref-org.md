---
type: Page
spec: "[[spec/org]]"
frozen:
  docs/specs/org.md: c7fe38aa9667
---
# Org

Org files are plain-text outlines. You fold headings, track TODOs, schedule them on dates, and see what's due in the agenda. Any file ending in `.org` opens in Org mode.

## Not yet in imp

- Repeating a task doesn't log it: there's no `LAST_REPEAT` property and no state-change notes.
- The calendar can't add a repeater; type one into the timestamp. Repeaters can't be hourly.
- Properties are only used for `CATEGORY`: there is no column view, no searching by property, and no special properties such as `ID` or `STYLE`.

## Headings and folding

A heading is a line starting with stars: `*` for the top level, `**` under it, and so on. The text below a heading belongs to it, down to the next heading of the same level or higher.

```org
* Projects
** Website
Notes about the website.
** Editor
* Reading list
```

| Key | What it does |
|---|---|
| `<tab>` | Fold or unfold the heading under the cursor: folded, then its children, then everything |
| `<s-tab>` | The same for the whole file |
| `M-<ret>` | Add a heading below |
| `M-h` / `M-l` | Promote or demote the heading |
| `M-H` / `M-L` | Promote or demote the heading with everything under it |
| `M-k` / `M-j` | Move the heading, and everything under it, up or down |

Drawers such as `:PROPERTIES:` … `:END:` start folded and fold again when you unfold their heading. Press `<tab>` on a drawer to open or close it.

`SPC m i` turns on indented display: each section is drawn indented under its heading. Only the display changes, not the file. In the window client, headings are drawn larger by level.

## TODOs and checkboxes

Put a TODO keyword after a heading's stars to make it a task. A list item starting with `[ ]` is a checkbox.

```org
* TODO Write the docs [1/2]
- [X] Install and first steps
- [ ] Configuring init.scm
```

| Key | What it does |
|---|---|
| `SPC m t` | Cycle the heading's TODO keyword: TODO, DONE, none |
| `SPC m x` | Tick or untick the checkbox |
| `<ret>` | Do what the line is for: follow a link, tick a checkbox, cycle a TODO, or align a table |
| `C-c ,` or `SPC m p` | Set the priority: `a`, `b` or `c`, or space to remove it |

A count such as `[1/2]` on the heading updates as you tick its boxes. A priority shows as `[#A]`, `[#B]` or `[#C]` after the keyword. In the agenda, a task without one counts as `B`.

To use other keywords, set `org-todo-keywords`. Keywords after a `"|"` count as done:

```scheme
(set-option! 'org-todo-keywords '("TODO" "NEXT" "|" "DONE" "CANCELLED"))
```

## Links

A link is written `[[target][description]]`. Away from the cursor's line, only the description shows. On the cursor's line the whole link shows, so you can edit it.

Press `<ret>` or `gx` on a link to follow it. A file opens in imp, and `file.org::12` jumps to line 12. A web address opens in your browser. `SPC m o` does the same, and `SPC m l` switches between showing links whole and showing their descriptions.

## Tables

Rows start with `|`. A row starting with `|-` becomes a rule.

```org
| Name | Done |
|------+------|
| Docs | yes  |
```

The table stays aligned as you type in a cell. `<tab>` moves to the next cell, and `SPC m b` aligns the table by hand.

## Dates and the calendar

| Key | What it does |
|---|---|
| `C-c C-s` or `SPC m s` | Schedule the heading: when you'll work on it |
| `C-c C-d` or `SPC m d` | Set a deadline: when it's due |
| `C-c .` or `SPC m .` | Put in a timestamp, or change the one under the cursor |

Each opens a calendar above the command line, showing three months. Move around with the arrow keys and PageUp and PageDown, or type a date:

| You type | You get |
|---|---|
| `fri` | Next Friday |
| `+3d` | Three days from today |
| `11-03` | 3 November |
| `tom 3pm` | Tomorrow at 3pm |

## Repeating tasks

End a timestamp with a repeater to make the task come back. When you mark it done, its date moves on and it goes back to TODO.

```org
* TODO Water the plants
  SCHEDULED: <2026-11-20 Fri +1w>
```

| Repeater | When you mark it done, the date moves |
|---|---|
| `+1w` | One week on from its date |
| `++1w` | By whole weeks until it's after today |
| `.+1w` | To one week after today |

Use `d`, `w`, `m` or `y` for days, weeks, months or years. A warning period such as `-3d` goes after the repeater. Picking a new date from the calendar keeps the repeater.

## Tags and effort

Press `C-c C-q` or `SPC m q` to tag the heading the cursor is under. Pick a tag from the ones your Org files use, or type a new one, and press `<ret>`. A tag the heading has already is taken off instead. It asks again, so you can change several; press `<esc>` when you're done. Tags the heading has are marked `on`.

```org
* TODO Write the report                                    :work:urgent:
```

Tags line up to end at column 77, as in Emacs. Set `org-tags-column` to change that.

Press `C-c C-x e` or `SPC m c E` to set the heading's effort: how long it should take, such as `0:45` or `1:30`. It's kept as the `Effort` property. An empty answer removes it.

## Properties

A heading's properties live in a drawer under it:

```org
* Write the docs
  :PROPERTIES:
  :OWNER: Ann
  :END:
```

Press `C-c C-x p` or `SPC m P` to set one. imp asks for the name, offering the names already used in the file, then the value. An empty value removes the property.

`CATEGORY` sets the label the agenda shows for an entry. It's inherited from parent headings, and `#+CATEGORY:` at the top of a file sets it for the whole file. Without one, the agenda shows the file's name.

In `init.scm`, `(org-entry-property line "OWNER")` gives a heading's property, and `(org-entry-property line "OWNER" #t)` also looks at its parents and the file's `#+PROPERTY:` lines.

## The agenda

`SPC o a` opens the agenda: this week's TODOs and dates from your agenda files. See [Org agenda](ref-org-agenda.md).

## Capture

`SPC o c` lets you jot something down without leaving what you're doing. Pick a template, and a `*capture*` buffer opens on the right.

| Key | Template | Goes to |
|---|---|---|
| `t` | Todo | under "Tasks" in your notes file |
| `n` | Note | under "Notes" in your notes file, with a link to where you were |
| `j` | Journal | today's date in `journal.org` |

In the capture buffer, `C-c C-c` or `:w` saves the entry, `C-c C-k` cancels it, and `C-c C-w` files it under any heading in your agenda files. If you didn't change the entry, nothing is saved.

Your notes file is `inbox.org` in `org-directory`, unless you set `org-default-notes-file`. Add your own templates with `define-capture-template!`:

```scheme
(define-capture-template! "w" "Work task" '(file+headline "work.org" "Inbox") "* TODO %?")
```

## Running code and exporting

- Running source blocks is the `org-babel` package. See [Packages](ref-packages.md).
- Exporting to HTML, PDF and other formats is the `org-export` package. See [Org export](ref-org-export.md).

## Options

| Option | Default | What it does |
|---|---|---|
| `org-directory` | `"~/org"` | Where your Org files live |
| `org-agenda-files` | `'()` | The files the agenda reads |
| `org-default-notes-file` | `""` | Where capture saves; empty means `inbox.org` in `org-directory` |
| `org-todo-keywords` | `'("TODO" "DONE")` | The keywords a heading cycles through |
| `org-tags-column` | `-77` | Where tags go: negative ends them at that column, positive starts them there |
| `org-link-descriptive` | `#t` | Show links as their descriptions away from the cursor |
| `org-fold-drawers` | `#t` | Start drawers folded |
| `org-indent` | `#f` | Indented display; `SPC m i` toggles it |
| `org-indent-per-level` | `2` | Columns each level indents by |
| `org-heading-heights` | `'(1.4 1.25 1.1)` | How much larger headings are drawn, from level 1 down, in the window client |
