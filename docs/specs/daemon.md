---
status: accepted
issue: https://github.com/apisandipas/imp/issues/3
summary: "imp --daemon and its clients, locally or over ssh."
anchors: [crates/imp-server/src/daemon.rs, crates/imp-server/tests/daemon.rs]
---
# Daemon

Buffers that survive closing the window, as with `emacs --daemon` ([[0004-client-and-server]]).

## Behaviour

- `imp --daemon` runs the editor with no client, listening on a Unix socket (`$XDG_RUNTIME_DIR/imp/default.sock`; `--name` or `--socket` pick another).
- `imp --connect [FILE...]` attaches a client and opens the files there. Several clients can attach; each gets frames at its own size, and the daemon keeps per-client facts (size, heights, cell width).
- Each client has its own windows, as Emacs gives each `emacsclient` its own frame ([[0015-daemon-clients-own-their-windows-and-share-the-typing]]): its layout, its current window, and each window's buffer, cursor and scroll. Splitting, closing, scrolling or switching windows or buffers in one client leaves the others as they were.
- Shared between clients: buffers, their text, undo, marks and registers, options and folds; and the typing state, as for one person moving between clients: the mode, pending keys, the command line, menus and the which-key popup, and messages.
- Two clients showing the same buffer each keep their own cursor in it; an edit through one moves the other's cursor with the text.
- A new client shows the files it was given (`imp --connect FILE`), else the buffer the most recently active client was on, in one window.
- A buffer deleted while another client's window shows it is replaced there by another buffer, as in a window of the same client.
- `:q` closes the client's current window; on its last window it detaches the client, and the daemon keeps running. `:kill-server` stops it.
- Remote: `imp --bridge` relays stdio to the local daemon, so `imp --connect --via 'ssh host imp --bridge'` runs a client here against a daemon there. The relay passes each read on at once.

## Known gaps

- Two people can't type at once: the mode, pending keys and command line are shared, so keys from two clients mix.
