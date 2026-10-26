---
type: Page
spec: "[[spec/completion]]"
frozen:
  docs/specs/completion.md: c12abe1827ac
---
# Completion at the prompt

When imp asks you to pick something, such as a command, a file or a buffer, a menu of choices opens under the prompt. Type a few letters and the menu narrows to what matches. For completion while you type in a buffer, see [Completion while typing](ref-completion-at-point.md).

## Opening the menu

| Key | What it does |
|---|---|
| `M-x` or `SPC :` | Run a command by name |
| `SPC f f` | Find a file |
| `SPC b b` | Switch to another buffer |

The help commands that describe a function, an option or a command use the same menu. See [Live Scheme and help](ref-live-scheme-and-help.md).

## Narrowing and choosing

Type to narrow the menu. Split what you type with spaces, and every part must match, in any order.

A part matches as plain text, or else as letters in order with gaps, so `ffl` finds `find-file`. The best matches come first.

| Key | What it does |
|---|---|
| `C-n` / `<down>` | Move down the menu |
| `C-p` / `<up>` | Move up the menu |
| `<ret>` | Take the selected choice, or what you typed when nothing matches |
| `<esc>` | Cancel |

For example, in `M-x`, typing `buf sw` finds `switch-buffer`.

## Running a command

`M-x` lists every command. Beside each one are its keys, in normal mode and under `SPC`, and a line saying what it does.

## Finding a file

`SPC f f` lists the files in your project. Inside a git repository, the files `.gitignore` ignores are left out. A long path is shortened from the start, so the file name stays in view.

Press `<tab>` to complete the path you typed one part at a time, as Emacs does. When there's nothing to add, `<tab>` moves down the menu instead.

To look somewhere else, start the path with `/`, `~/`, `./` or `../`. The menu then lists that directory, matching on the part after the last `/`. Hidden files are left out.

## Switching buffers

`SPC b b` lists your other buffers. The buffer you were in last comes first, so `SPC b b` then `<ret>` takes you back.

## In init.scm

`completing-read` opens the same menu with your own choices. It takes a prompt, a list of strings, and what to do with the one chosen:

```scheme
(completing-read "Open: " '("notes.org" "todo.org") open-file!)
```
