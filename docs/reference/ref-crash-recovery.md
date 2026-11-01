---
type: Page
spec: "[[spec/crash-recovery]]"
frozen:
  docs/specs/crash-recovery.md: 8b128ad9ed63
---
# Crash recovery

If imp crashes, or your machine loses power, your unsaved changes aren't lost. imp keeps a private copy of every buffer you've changed, and offers it back when you open the file again.

## Not yet in imp

- Most of this page is still to be built ([#130](https://github.com/apisandipas/imp/issues/130)). Until then, imp copies changed files every `autosave-interval` seconds, doesn't copy unnamed buffers, and tells you about a copy with a message instead of asking. See [Files](ref-files.md).

## How your changes are kept

A few seconds after you stop typing, imp copies each changed buffer to disk. If you keep typing without a pause, it still copies every 30 seconds. So a crash loses at most the last few seconds of work.

A buffer that hasn't changed since its last copy isn't written again. An idle imp doesn't touch the disk.

Unnamed buffers you type into, like one from `:enew`, are copied too. Terminals, the REPL, file browsers and other buffers whose names start with `*` are not.

## Where the copies go

Copies go in the `autosave` folder of imp's state directory, `~/.local/state/imp/autosave` by default. Nothing is written beside your files, so your projects and `git status` stay clean.

Only you can read them. The folder is private to you, and so is each copy, even when the file itself is readable by others.

## Opening a file after a crash

When you open a file that has a copy left from a crash, imp asks what to do:

```
notes.org has unsaved changes from a crash, saved 14:02 (12 lines differ)
r recover   d delete the copy   k keep it for later
```

| Key | What it does |
|---|---|
| `r` | Put the copy's text in the buffer. `u` undoes it; `:w` keeps it |
| `d` | Delete the copy and keep the file as it is |
| `k` or `Esc` | Leave both alone and ask again next time |

If the file was changed after the copy was made, imp tells you so before you choose. If the copy matches the file, imp deletes it without asking.

If another imp is running with the same file open, imp tells you once and opens the file as usual. Nothing stops you editing it in both.

## Recovering later

| Command | What it does |
|---|---|
| `:recover` or `:rec` | Put the crash copy of this buffer's file in the buffer |
| `:recover FILE` | Open FILE and recover it |
| `M-x recover-session` | List every copy left by a crash, newest first, and pick one to recover |

`recover-session` also lists unnamed buffers. Picking one opens a new buffer with its text.

## When copies are deleted

A copy is deleted once your changes are safe or you've thrown them away:

- when you save the buffer;
- when the buffer goes back to the saved text, with `:e!`, a reload, or undo;
- when you kill the buffer, or quit with `:qa!`.

Quitting any other way keeps the copies of buffers you haven't saved, and imp offers them the next time you open those files. Detaching from the daemon with `:q` keeps everything as it is.

Only the text comes back. Your cursor, undo history and open windows don't.

## Options

| Option | Default | What it does |
|---|---|---|
| `autosave-idle` | `4` | Seconds without typing before changed buffers are copied; `0` copies only on the interval |
| `autosave-interval` | `30` | Most seconds a change waits to be copied while you keep typing; `0` turns copies off |
| `state-directory` | `""` | Where copies go; empty means `$XDG_STATE_HOME/imp` |

```scheme
(set-option! 'autosave-idle 2)
```
