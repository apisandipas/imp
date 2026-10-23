---
status: accepted
summary: "imp --daemon and its clients, locally or over ssh."
anchors: [crates/imp-server/src/daemon.rs, crates/imp-server/tests/daemon.rs]
---
# Daemon

Buffers that survive closing the window, as with `emacs --daemon` ([[0004-client-and-server]]).

## Behaviour

- `imp --daemon` runs the editor with no client, listening on a Unix socket (`$XDG_RUNTIME_DIR/imp/default.sock`; `--name` or `--socket` pick another).
- `imp --connect [FILE...]` attaches a client and opens the files there. Several clients can attach; each gets frames at its own size, and the daemon keeps per-client facts (size, heights, cell width).
- `:q` in a client detaches it and the daemon keeps running; `:kill-server` stops it.
- Remote: `imp --bridge` relays stdio to the local daemon, so `imp --connect --via 'ssh host imp --bridge'` runs a client here against a daemon there. The relay passes each read on at once.

## Known gaps

- Clients share one cursor and layout, like tmux sessions; only their sizes are their own, so scrolling can differ per size.
