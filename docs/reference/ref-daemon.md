---
type: Page
spec: "[[spec/daemon]]"
frozen:
  docs/specs/daemon.md: 52dfa8b283fe
---
# Daemon

Run imp as a daemon, and your buffers outlive the window you were editing in. Close the window, connect again later, and everything is where you left it, as with `emacs --daemon`.

## Not yet in imp

- Two people can't type at once. Clients share the mode, pending keys and command line, so keys from two clients mix.

## Starting and connecting

```sh
imp --daemon               # the editor, with no window, on a socket
imp --connect notes.org    # a client: attach and open notes.org
```

`imp --connect` with no files shows the buffer the most recently active client was on. Either way, a new client starts with one window.

The daemon listens on `$XDG_RUNTIME_DIR/imp/default.sock`. To run more than one, give each a name with `--name`, or a socket path with `--socket`, and pass the same to `--connect`.

## Leaving and stopping

`:q` closes the client's current window. On its last window, it detaches the client, and the daemon keeps running with your buffers.

`:kill-server` stops the daemon.

## Several clients

Any number of clients can attach at once, each at its own size. Each has its own windows, as each `emacsclient` gets its own frame: its layout, its current window, and each window's buffer, cursor and scroll. Splitting, closing or scrolling windows in one client, or switching buffers, leaves the others as they were.

Clients share everything else:

- Buffers, their text and undo, marks, registers, options and folds.
- The typing, as if one person were moving between clients: the mode, pending keys, the command line, menus, the which-key popup and messages.

Two clients on the same buffer each keep their own cursor in it. An edit in one moves the other's cursor along with the text. If you delete a buffer another client is showing, that client's window switches to another buffer.

## Connecting from another machine

`imp --bridge` passes a client's traffic to the daemon on its own machine. Run it over ssh to edit with a daemon on a remote host:

```sh
imp --connect --via 'ssh host imp --bridge'
```

The client runs here, and the buffers live on `host`.
