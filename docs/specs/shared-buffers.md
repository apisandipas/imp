---
status: accepted
summary: "Collaborative editing of a buffer over a socket with a CRDT, behind the crdt feature."
anchors: [runtime/collab.scm, crates/imp-server/src/crdt.rs, crates/imp-server/tests/crdt.rs]
---
# Shared buffers

A prototype, built carefully: the CRDT is `yrs` (the Rust Yjs), not hand-written. Off unless built with `--features crdt`.

## Behaviour

- A shared buffer keeps a yrs document beside its rope as a mirror. Local changes are found by comparing the buffer with the mirror, so every way of editing is covered without hooks; remote changes arrive as ordinary edits, so marks, the cursor and the syntax tree follow.
- `:share [NAME]` serves the current buffer on a socket, `:join [NAME]` opens one from another editor, `:unshare` stops. The host relays updates between guests; each side syncs after every command and every 200 ms.
- A NAME with a slash is a socket path, so `:join` can reach any socket the user can. Joining trusts the peer on it: its buffer content and every change it sends become the joined buffer's text unchecked. A message line longer than 64 MiB closes the connection.

## Known gaps

- Undo is still local and by text snapshot, so `u` after a remote edit can undo it too.
- Other cursors aren't shown.
