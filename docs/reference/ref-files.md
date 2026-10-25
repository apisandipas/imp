---
type: Page
spec: "[[spec/files]]"
frozen:
  docs/specs/files.md: b08542837535
---
# Files

imp saves your files safely, keeps their line endings and encoding, and notices when another program changes them. It also keeps autosaved copies, remembers the files you open, and can delete, rename and copy files for you.

## Saving

`:w` saves the buffer. imp writes the new text to a temporary file beside yours, then puts it in place. A crash never leaves half a file, and the file keeps its permissions.

Turn on `backup` to keep the previous version of a file as `FILE~` each time you save:

```scheme
(set-option! 'backup #t)
```

## Line endings and encodings

imp keeps a file the way it found it. A file with Windows (CRLF) line endings is written back with them, and a UTF-8 byte order mark is kept.

A file that isn't valid UTF-8 opens as Latin-1 and is saved as Latin-1. To change a file's line endings, set `fileformat` and save: `:set ff=unix` or `:set ff=dos`.

## When a file changes on disk

imp checks your files every few seconds, and when you switch to a buffer. If another program changed a file and you haven't touched its buffer, the buffer reloads. Turn off `autoread` to stop that.

If you have changed the buffer too, imp warns you instead. `:w` then refuses to overwrite the file. Use `:w!` to save over it anyway.

## Autosave and recovery

Every `autosave-interval` seconds, imp copies each buffer with unsaved changes into its state directory. If imp or your machine crashes, open the file again. When the autosaved copy is newer, imp says so; `:recover` puts it in the buffer, and `:w` keeps it.

## Deleting, renaming and copying files

| Key | What it does |
|---|---|
| `SPC f D` | Delete a file |
| `SPC f R` | Rename or move a file |
| `SPC f C` | Copy a file |

Each asks for the file, starting from the current buffer's. Delete asks again before it deletes, and won't delete a directory. If the file's buffer has unsaved changes, the buffer stays open.

Renaming moves the buffer with the file, so it keeps showing it under its new name. It won't overwrite a file that's already there. If you name a directory, the file goes into it.

Copying leaves the buffer on the original file. Binary files copy whole, and the copy keeps the file's permissions.

## Recent files

`SPC f r` lists the files you've opened recently. Pick one to open it again. The list is kept in the state directory, so it lasts between sessions.

## Options

| Option | Default | What it does |
|---|---|---|
| `autoread` | `#t` | Reload a file changed on disk when its buffer has no changes |
| `backup` | `#f` | Keep the previous version as `FILE~` on each save |
| `autosave-interval` | `30` | Seconds between autosaves |
| `state-directory` | `""` | Where autosaves and recent files go; empty means `$XDG_STATE_HOME/imp` |
