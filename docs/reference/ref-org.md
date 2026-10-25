---
type: Page
spec: "[[spec/org]]"
frozen:
  docs/specs/org.md: eacefd3dbd04
---
# Org

Org files are plain-text outlines. You fold headings, track TODOs, schedule them on dates, and see what's due in the agenda. Any file ending in `.org` opens in Org mode.

## Not yet in imp

- Changing a keyword never asks for a note.
- The calendar can't add a repeater; type one into the timestamp. Repeaters can't be hourly.
- Properties are only used for `CATEGORY`, `Effort`, a habit's `STYLE`, `LAST_REPEAT` and the agenda's matches: there is no column view, and no special properties such as `ID`.

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

## Logging

When you mark a heading done, imp notes when on its planning line. Moving it back out of done takes the note away again, and so does undo.

```org
* DONE Write the report
CLOSED: [2026-10-25 Sun 11:42] SCHEDULED: <2026-10-24 Sat>
```

When you mark a repeating task done, imp sets its `LAST_REPEAT` property and logs the change at the top of its `:LOGBOOK:` drawer, which it makes if there isn't one. Habits in the agenda read these lines.

```org
* TODO Water the plants
SCHEDULED: <2026-11-27 Fri +1w>
:PROPERTIES:
:LAST_REPEAT: [2026-11-20 Fri 18:05]
:END:
:LOGBOOK:
- State "DONE"       from "TODO"       [2026-11-20 Fri 18:05]
:END:
```

Set `org-log-done` or `org-log-repeat` to `#f` to stop either.

## Clocking

Clock in on a heading to keep track of the time you spend on it.

| Key | What it does |
|---|---|
| `C-c C-x C-i` or `SPC m c i` | Clock in on the heading the cursor is under |
| `C-c C-x C-o` or `SPC m c o` | Clock out |
| `C-c C-x C-q` or `SPC m c c` | Cancel the clock, as if you never clocked in |
| `C-c C-x C-j` or `SPC m c g` | Go to the heading you're clocked in on |

Clocking in adds a line to the heading's `:LOGBOOK:` drawer, and clocking out ends it with the time it ran:

```org
* TODO Write the report
:LOGBOOK:
CLOCK: [2026-10-25 Sun 11:42]--[2026-10-25 Sun 12:57] =>  1:15
:END:
```

One clock runs at a time: clocking in on another heading clocks out of the first. While it runs, the status line shows how long it has run, the heading's effort if it has one, and its title, as `[0:23/1:00] Write the report`. If you quit with a clock running, imp picks it up again the next time it starts, as long as the file is one of your agenda files.

## Tags and effort

Press `C-c C-q` or `SPC m q` to tag the heading the cursor is under. Pick a tag from the ones your Org files use, or type a new one, and press `<ret>`. A tag the heading has already is taken off instead. It asks again, so you can change several; press `<esc>` when you're done. Tags the heading has are marked `on`.

```org
* TODO Write the report                                    :work:urgent:
```

Tags line up to end at column 77, as in Emacs. Set `org-tags-column` to change that.

Press `C-c C-x e` or `SPC m c E` to set the heading's effort: how long it should take, such as `0:45` or `1:30`. It's kept as the `Effort` property. An empty answer removes it.

## Moving a heading elsewhere

Press `C-c C-w` or `SPC m r` to refile the heading the cursor is under: pick any heading in your agenda files, and the heading moves there with everything under it. It goes at the end of what's under the new heading, one level below it. Undo puts it back when it moves within the same file.

## Archiving

Press `C-c C-x C-a` or `SPC m A` to archive the heading the cursor is under, with everything under it. It moves to the end of an archive file next to yours, `work.org_archive` for `work.org`, made if it doesn't exist. The agenda doesn't read archives.

The heading keeps a note of where it came from, in properties:

```org
* TODO Old task
:PROPERTIES:
:ARCHIVE_TIME: 2026-10-25 Sun 11:42
:ARCHIVE_FILE: /home/you/org/work.org
:ARCHIVE_OLPATH: Projects
:ARCHIVE_CATEGORY: work
:ARCHIVE_TODO: TODO
:END:
```

To archive somewhere else, set `org-archive-location`: a file name, where `%s` is your file's name, then `::` and a heading to file under, if you want one.

```scheme
(set-option! 'org-archive-location "archive.org::* From %s")
```

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

`SPC o a a` opens the agenda: this week's TODOs and dates from your agenda files. See [Org agenda](ref-org-agenda.md).

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
| `org-log-done` | `'time` | Note when a heading is marked done, as `CLOSED:` |
| `org-log-repeat` | `'time` | Log each repeat in the `:LOGBOOK:` drawer |
| `org-archive-location` | `"%s_archive::"` | Where archiving moves a heading: a file, then `::` and a heading |
| `org-tags-column` | `-77` | Where tags go: negative ends them at that column, positive starts them there |
| `org-link-descriptive` | `#t` | Show links as their descriptions away from the cursor |
| `org-fold-drawers` | `#t` | Start drawers folded |
| `org-indent` | `#f` | Indented display; `SPC m i` toggles it |
| `org-indent-per-level` | `2` | Columns each level indents by |
| `org-heading-heights` | `'(1.4 1.25 1.1)` | How much larger headings are drawn, from level 1 down, in the window client |
