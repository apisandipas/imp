---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/130
summary: "Unsaved changes survive a crash: modified buffers are copied to private autosave files a few seconds after typing stops, and reopening the file offers them back, as Vim's swap files and Emacs' auto-save do."
anchors: [runtime/files.scm]
---
# Crash recovery

Unsaved changes survive a crash: modified buffers are copied to private autosave files a few seconds after typing stops, and reopening the file offers them back, as Vim's swap files and Emacs' auto-save do.

A panic in the editor, a `kill -9`, an out-of-memory kill or a power cut all end the process without a word, and under the daemon ([[spec/daemon]]) one crash takes every client's buffers with it. This spec replaces the **Autosave** line of [[spec/files]] and builds on what is there: `autosave-interval`, the copies in the state directory, and `:recover`.

## Behaviour

### One mechanism: autosave copies

- Recovery rests on one thing only: copies written to disk while imp runs normally. There is no panic hook and no write at exit.
  - A copy written ahead of time covers every way imp can die; a panic hook covers only a panic, not SIGKILL, the OOM killer or a power cut, so it would be a second path to build and test for the rarest case.
  - A panic can strike while editor state is half-changed and borrowed ([[0012-one-thread-owns-the-vm-and-the-editor]]), so a hook writing buffers from it could itself fail or write garbage.
  - What is lost is bounded by the timing below: at most the last `autosave-idle` seconds of typing, or `autosave-interval` seconds of nonstop typing.
- **When**: a buffer whose text has changed since its last copy (or since it was read or saved) is copied
  - once no client has sent a key or mouse event for `autosave-idle` seconds (default 4, Vim's `updatetime`), and
  - at the latest `autosave-interval` seconds (default 30) after its first change not yet copied, so steady typing is still covered.
  - A buffer whose text hasn't changed since its last copy is not written again: an idle imp does no disk writes.
  - Changing either option takes effect from the next change; no restart. `autosave-interval` 0 turns autosave off; `autosave-idle` 0 leaves only the interval.
- **What is copied**: the buffer's whole text, as UTF-8 with `\n` line endings. Line endings and encoding come from the file again on recovery.
- **Which buffers**:
  - every buffer visiting a file with unsaved changes;
  - every unnamed buffer (no file) with text in it that is an ordinary text buffer: not read-only, its major mode not derived from `special-mode`, not a terminal, and its name not starting with `*` (so `*Messages*`, the REPL, Dired and package buffers are skipped).
- A copy that can't be written (disk full, unwritable state directory) is skipped; imp says so once per buffer on the message line and keeps editing.

### Where copies go, and privacy

- Copies live in `STATE/autosave/`, where `STATE` is the `state-directory` option (default `$XDG_STATE_HOME/imp`, else `~/.local/state/imp`), not beside the file as Vim does: nothing appears in project directories or in git status, and a file in a read-only or shared directory is covered too.
- `STATE/autosave/` is created with mode `0700`; if it exists with looser permissions and belongs to the user, imp sets it to `0700`. Each copy is created `0600`, whatever the original file's mode, since a buffer may hold a secret the file never had.
- A copy is written atomically (a temporary file in the same directory, then a rename), so a crash during a write leaves the previous copy whole.
- A copy's name records whose it is:
  - a file's copy is its absolute path with each `/` made `%`, then `#` and the writing process's id: `%home%me%notes.org#4242`;
  - an unnamed buffer's copy is `unnamed-N#PID`, N the buffer's number.
  - Copies named in the old form, without `#PID`, are treated as orphaned (below).
- A file whose copy's name would be longer than 255 bytes isn't autosaved; imp says so once when the buffer is first modified.

### In use or orphaned

- A copy is **in use** when its process id belongs to a running imp, and **orphaned** otherwise: the imp that wrote it has died.
- Only orphaned copies are offered for recovery. Opening a file that another running imp also has a copy of says `FILE is also being edited in imp PID` once, as Vim's "swap file exists" warns of two editors, and opens it as usual.

### Opening a file that has an orphaned copy

- When a file's buffer is first shown in a window, imp looks for orphaned copies of that file. Buffers opened without a window (by LSP, grep and the like) are checked when first shown.
- If the newest orphaned copy has the same text as the file, the copy is deleted without a word.
- Otherwise imp asks on the message line, with a popup above it as `confirm!` shows:

  ```
  notes.org has unsaved changes from a crash, saved 14:02 (12 lines differ)
  r recover   d delete the copy   k keep it for later
  ```

  - The time is when the copy was written. If the file on disk is newer than the copy, the popup says so (`the file was changed after this copy`), as Vim warns when a file is newer than its swap file.
  - `r` replaces the buffer's text with the copy's as one change (`u` undoes it), leaves the buffer modified, and says `recovered notes.org; :w to keep it`. The orphaned copy then becomes this imp's copy of the buffer: it is renamed to this process's name, so a second crash before the next autosave still has it.
  - `d` deletes the copy and leaves the buffer as the file is.
  - `k`, `Esc` or any other key leaves both alone; the copy is offered again the next time the file is opened, and `:recover` takes it now.
- With several orphaned copies of one file (two crashes, or two imps), the prompt and `:recover` take the newest; `M-x recover-session` lists them all.

### Commands

- `:recover` (`:rec`) puts the newest orphaned copy of the current buffer's file in the buffer, as `r` does, without asking. With no orphaned copy it says `no autosaved copy of this buffer`.
- `:recover FILE` opens FILE, as `:e` does, and then recovers it as `:recover` does, as Vim's `:recover FILE` does.
- `M-x recover-session`, after Emacs' `recover-session` and `vim -r`, lists every orphaned copy in a picker, newest first: the file's path (or `unnamed`), when it was written, and its size in lines. Choosing a file's copy opens the file and recovers it as `:recover` does; choosing an unnamed copy opens a new unnamed buffer holding its text, modified. With no orphaned copies it says `nothing to recover`.
- No leader key: recovery is rare and mostly comes up through the prompt when a file opens, and `SPC f` is crowded.

### Cleanup

A copy goes as soon as the changes it protects are no longer at risk:

- after the buffer is saved (`:w`, `:wa`, `SPC f s`);
- when the buffer becomes unmodified another way: `:e!`, a reload after an outside change, or undoing back to the saved text (at the next autosave check);
- when the buffer is killed (`:bd!`, a buffer killed with its changes thrown away), and for an unnamed buffer when it is killed or emptied;
- when `:qa!`, or `:q!` on the last window of a standalone imp, ends imp: they throw changes away on purpose, as Vim deletes its swap files then (a daemon client's `:q!` only detaches it, below);
- when a renamed buffer's file moves (`rename-file`), the old copy is deleted and the next copy is written under the new name.

In a daemon, `:qa!` and `:q!` detach the client as `:q` does and end nothing, so they delete no copies: the daemon still has the buffers, and their copies stay in use until the buffers are saved or killed. Only throwing changes away *and* ending the process deletes them.

Ending without throwing changes away keeps the copies of buffers that still have unsaved changes, as Emacs keeps auto-save files: `:kill-server`, the daemon stopped by a signal, or a terminal closed under a standalone imp. Their copies are orphaned once the process is gone and are offered at the next open. `:kill-server` discards unsaved changes without asking, as it always has; its copies make that recoverable. A daemon client detaching (`:q` on its last window) changes nothing: the daemon still runs and its copies stay in use.

### Daemon

- One daemon is one process with one set of copies for every client's buffers. The idle time counts input from all clients together.
- The open prompt goes to the client that is typing, as every other prompt does ([[0015-daemon-clients-own-their-windows-and-share-the-typing]]).

### Where it lives

Behaviour is Scheme ([[0005-rust-owns-data-and-speed-scheme-owns-behavior]]), in `runtime/files.scm`, where autosave already is. It stays in the core rather than a package ([[0011-non-essential-features-are-opt-in-packages]]): not losing work is essential to editing.

- **Scheme**: the idle and interval timers, which buffers to copy and when, copy names, finding orphaned copies, the open prompt, `:recover`, `recover-session`, and every cleanup rule.
- **Rust primitives**, only what Scheme can't do:
  - `write-private-file! PATH TEXT`: writes atomically, the file created `0600` and its directory `0700`, tightening the directory if it is the user's and looser.
  - `process-id`: this process's id.
  - `imp-running? PID`: whether a process with that id is running and is imp (by its executable name where the system tells; Linux's `/proc/PID/exe` or `comm`, `kill(PID, 0)` elsewhere).
  - The idle time: when the last key or mouse event arrived from any client, or a hook that fires once input has stopped for a given time; whichever the existing timer code makes simpler.
  - Existing primitives cover the rest: `buffer-version`, `buffer-modified?`, `buffer-list`, `directory-entries`, `file-mtime`, `read-file`, `delete-file!`.

## Keys and options

`:recover` (`:rec`), `:recover FILE`, `M-x recover-session`; the open prompt's `r`, `d` and `k`. Options: `autosave-idle` (seconds, 4), `autosave-interval` (seconds, 30; 0 turns autosave off), `state-directory` (`""`, meaning `$XDG_STATE_HOME/imp`). No leader key.

## Out of scope

- A panic hook, `catch_unwind` or a write at exit; see above.
- Copies beside the file, as Vim's default `directory` puts them, and a `.#FILE` lock file as Emacs makes.
- Keeping undo history, cursor, marks, folds or window layout across a crash; only the text comes back. Persistent undo is a separate feature.
- Restoring the whole session (which buffers and windows were open) by itself; `recover-session` brings back the text of each buffer the user picks.
- A command-line flag such as `vim -r` or `imp --recover`; `M-x recover-session` serves.
- Locking a file against a second editor: imp warns when another imp has the file open, but doesn't stop either.
- Cleaning up old orphaned copies by age; they stay until recovered or deleted from the prompt.
- Autosaving terminal, REPL or package buffers, and buffers with no text.
- Writing copies off the editor thread; a very large modified buffer costs one write per copy.
- Windows: modes `0600`/`0700` and process checks are Unix only.

## Known gaps

- Not built yet ([#130](https://github.com/apisandipas/imp/issues/130)). Until it is, imp works as [[spec/files]] says: every modified file buffer is copied every `autosave-interval` seconds, privately but with no record of which imp wrote it, unnamed buffers aren't copied, and `:recover` is offered by a message rather than a prompt.
