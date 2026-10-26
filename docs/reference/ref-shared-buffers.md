---
type: Page
spec: "[[spec/shared-buffers]]"
frozen:
  docs/specs/shared-buffers.md: edc911376d67
---
# Shared buffers

Share a buffer, and other editors can join it and edit it with you. Everyone's changes are merged as they type. It's a prototype, only in an imp built with `--features crdt`.

## Not yet in imp

- Undo is still local: `u` after someone else's edit can undo theirs too.
- You can't see other people's cursors.

## Sharing a buffer

| Command | What it does |
|---|---|
| `:share [NAME]` | Share the current buffer under a name, `imp` if you don't give one |
| `:join [NAME]` | Open the buffer shared under that name, in a new buffer |
| `:unshare` | Stop sharing, or leave a buffer you joined |

The editor that shares the buffer passes changes between everyone who joined. Each side sends its changes after every command, and every 200 ms.

Changes from others arrive as ordinary edits. Marks, your cursor and syntax highlighting follow them. Whatever way you edit, your changes are shared.
