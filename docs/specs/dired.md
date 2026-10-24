---
status: accepted
summary: "An oil-style editable directory listing."
anchors: [runtime/dired.scm, crates/imp-server/tests/dired.rs]
---
# File browser

## Behaviour

- `:Ex`, `SPC f d`, `:e DIR` or `imp DIR` open a directory as a buffer, one name per line, directories ending in `/`. `<ret>` opens an entry, `-` goes up, `q` returns to the file it was opened from.
- The listing is text: rename a line to rename the file, delete a line to delete it, add a line to create a file (or a directory, ending in `/`). `:w` shows the renames, deletions and creations and asks first. A name both deleted and created (`dd` then `p`) is no change, so moving lines never deletes a file.
- Names swapped between entries (or rotated) are renames: an entry whose mark is alone at the start of a line that now reads another entry's name is that line, when the other entry's line was renamed too. Otherwise a line that reads exactly as an entry did is that entry, and failing that the entry's sticky mark at the start of its line says which line it became.
- Details (permissions, size, time) in the margin beside each entry; `(` toggles them. `g.` shows dotfiles.
- One browser buffer, reused as you change directory unless it has unsaved edits.

## Keys and options

`dired-show-hidden`, `dired-details`, `dired-reuse-buffer`.
