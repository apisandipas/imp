---
status: accepted
issue: https://github.com/apisandipas/imp/issues/3
summary: "imp --daemon and its clients, locally or over ssh."
anchors: [crates/imp-server/src/daemon.rs, crates/imp-server/tests/daemon.rs]
---
# Daemon

Buffers that survive closing the window, as with `emacs --daemon` ([[0004-client-and-server]]).

## Behaviour

- `imp --daemon` runs the editor with no client, listening on a Unix socket (`$XDG_RUNTIME_DIR/imp/default.sock`; `--name` or `--socket` pick another). A `--name` is a plain name, `NAME.sock` in that private directory: an empty one, or one with `/` or `..`, is an error saying to use `--socket` for a path.
- Limits, so a client can't make the daemon allocate without bound: a message line longer than 16 MiB disconnects the client, and a client's size is clamped to 4096 columns and rows. Clients likewise stop reading at a line from the server longer than 256 MiB.
- `imp --connect [FILE...]` attaches a client and opens the files there. Several clients can attach; each gets frames at its own size, and the daemon keeps per-client facts (size, heights, cell width).
- Each client has its own windows, as Emacs gives each `emacsclient` its own frame ([[0015-daemon-clients-own-their-windows-and-share-the-typing]]): its layout, its current window, and each window's buffer, cursor and scroll. Splitting, closing, scrolling or switching windows or buffers in one client leaves the others as they were.
- Shared between clients: buffers, their text, undo, marks and registers, options and folds; and the typing state, as for one person moving between clients: the mode, pending keys, the command line, menus and the which-key popup, and messages.
- Two clients showing the same buffer each keep their own cursor in it; an edit through one moves the other's cursor with the text.
- A new client shows the files it was given (`imp --connect FILE`), else the buffer the most recently active client was on, in one window.
- A buffer deleted while another client's window shows it is replaced there by another buffer, as in a window of the same client.
- `:q` closes the client's current window; on its last window it detaches the client, and the daemon keeps running. `:kill-server` (or `M-x kill-server`) stops it, for every client.
- `:kill-server` refuses while any buffer has unsaved changes, as `:qa` does and as Emacs' `save-buffers-kill-emacs` asks first: it goes to the first such buffer and says `unsaved changes in NAME (:kill-server! stops anyway)`. With none, it asks `stop the programs running in N terminals? (y or n)` if programs are running in terminals ([[spec/terminals]]), since they stop too; unsaved changes are checked first, so a refusal never follows a yes. `:kill-server!` stops at once, asking nothing, as `:qa!` quits; the copies of unsaved buffers are kept, so they can be recovered ([[spec/crash-recovery]]). Without a daemon, `:kill-server` quits imp the same way.
- Remote: `imp --bridge` relays stdio to the local daemon, so `imp --connect --via 'ssh host imp --bridge'` runs a client here against a daemon there. The relay passes each read on at once.

## Known gaps

- Two people can't type at once: the mode, pending keys and command line are shared, so keys from two clients mix.
