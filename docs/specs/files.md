---
status: accepted
summary: "Saving and reading files: atomic saves, encodings, outside changes, autosave, and file commands."
anchors: [crates/imp-core/src/fileio.rs, crates/imp-server/src/files.rs, runtime/files.scm, crates/imp-server/tests/files.rs, crates/imp-server/tests/file_commands.rs]
---
# Files

## Behaviour

- **Saves are atomic**: a temporary file beside the target, then a rename, keeping its permissions and, where allowed, its owner. The temporary file has the target's permissions from the start and an unguessable name; neither it nor `FILE~` follows a symlink planted at its name. `backup` keeps `FILE~`.
- **Formats**: CRLF line endings are detected and written back (`fileformat`); a UTF-8 BOM is kept; invalid UTF-8 opens as Latin-1 and is written back as Latin-1.
- **Outside changes**: checked on a timer and when entering a buffer. An unmodified buffer reloads (`autoread`); a modified one gets a warning, and `:w` refuses to overwrite until `:w!`.
- **Autosave**: modified buffers are copied every `autosave-interval` seconds into the state directory, each copy `0600` in a `0700` directory; `:recover` restores one.
- **File commands**: `delete-file`, `rename-file` and `copy-file` (`SPC f D`, `SPC f R`, `SPC f C`). Delete offers the current buffer's file, asks first, refuses directories, and keeps a buffer that has unsaved changes. Rename moves the buffer with the file (path, major mode, and the `buffer-renamed` hook) and won't overwrite a file; a directory as the target means "into it". Copy keeps the buffer on the original and copies binary files and permissions.
- **Recent files**: visited files are kept in the state directory; `SPC f r` picks one.

## Keys and options

`autoread`, `backup`, `autosave-interval`, `state-directory` (default `$XDG_STATE_HOME/imp`).

