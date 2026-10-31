---
type: Page
spec: "[[spec/dired]]"
frozen:
  docs/specs/dired.md: a02aeaac49d8
---
# File browser

The file browser lists a directory as a buffer you can edit. Rename, delete and create files by editing the lines, then save to make the changes.

## Opening a directory

Press `SPC f d` to browse the current file's directory. `:Ex` does the same, and `:Ex DIR`, `:e DIR` or `imp DIR` open any directory.

The browser lists one name per line. Directories end in `/`.

| Key | What it does |
|---|---|
| `<ret>` | Open the file or directory under the cursor |
| `-` | Go up to the parent directory |
| `q` | Close the browser and go back to your file |
| `g.` | Show or hide dotfiles |
| `(` | Show or hide the details |

The details are each entry's permissions, size and time, shown beside it. They aren't part of the text, so you can't change them by mistake.

imp keeps one browser buffer and reuses it as you move between directories. If it has edits you haven't saved, a new one opens instead.

## Changing files by editing

The listing is ordinary text, and the usual Vim keys work on it.

| To | Do this |
|---|---|
| Rename a file | Change its line |
| Delete a file | Delete its line |
| Create a file | Add a line with its name |
| Create a directory | Add a line ending in `/` |

Nothing happens until you save. `:w` lists the renames, deletions and new files, and asks first. Press `y` to make them; any other key closes the list and the question together.

Moving a line with `dd` and `p` changes nothing, so it can't delete a file by accident. Swapping two names, or rotating several, renames each file.

## Options

| Option | Default | What it does |
|---|---|---|
| `dired-show-hidden` | `#f` | Show dotfiles; `g.` toggles it |
| `dired-details` | `#t` | Show permissions, size and time; `(` toggles it |
| `dired-reuse-buffer` | `#t` | Reuse the browser buffer when you change directory |
