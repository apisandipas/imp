---
type: Decision
status: accepted
anchors: ["crates/imp-core/src/protocol.rs", "crates/imp-server/src/daemon.rs"]
---
# Client and server

## Context
Emacs's daemon and Neovim's UIs show the value of an editor whose state outlives its window: reattaching, remote editing, several front ends.

## Decision
The server owns all editor state; clients only send input (`ClientMsg`) and draw what the server sends (`Frame`, then `Patch`es). Standalone, the server runs on a thread in the client's process over channels; with `imp --daemon` it listens on a Unix socket and clients speak JSON lines.

## Consequences
- The terminal and window clients are just two clients of one protocol, and `--via` gives remote editing over ssh.
- Clients hold no editor logic, so a feature is built once, in the server.
- Daemon clients share one cursor and layout, like tmux sessions; each has only its own size.
