---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/135
summary: "The imp command line: how imp picks a window or the terminal, and every flag and environment variable it takes."
anchors: [crates/imp/src/main.rs, crates/imp-gui/src/lib.rs]
---
# Command line

What `imp` takes on its command line, and how it picks between the window and the terminal. The daemon's flags are described in [[spec/daemon]] and the agent socket's in [[spec/mcp]]; this spec lists them all in one place.

## Behaviour

- `imp [FILE...]` starts the editor and opens the files: a directory opens in the file browser ([[spec/dired]]); with none, the start screen shows ([[spec/start-screen]]).
- **Window or terminal**: imp opens a window when there is a display (`$WAYLAND_DISPLAY` or `$DISPLAY`; on macOS, any session but SSH) and uses the terminal it was started in otherwise. `--tui` always uses the terminal. If the window can't open after all (a stale `$WAYLAND_DISPLAY` inside tmux, say), imp falls back to the terminal, unless a window flag was given, when it stops with the error and says `imp --tui` uses the terminal instead.
- **Window flags**, each taking a value:
  - `--font FAMILY`: the font family; it wins over the `font` option ([[spec/look]]). Default: the option, else the system's monospace.
  - `--font-file PATH`: load a font file besides the system's fonts, so `--font` or the `font` option can name a font that isn't installed. It can be given more than once.
  - `--font-size PX`: the font size in pixels; it wins over the `font-size` option. Default: the option, else 15.
  - `--scale F`: multiplies the font size, on top of the display's own scale factor, for HiDPI screens. Default: `$IMP_GUI_SCALE`, else 1.
  - `--screenshot OUT.png`: draw the editor off-screen, without a display, and save it as a PNG, then exit. `--grid COLSxROWS` sets its size in cells (default `100x30`); `--keys KEYS` types keys first, characters as themselves and other keys in angle brackets (`ihello<esc>`, `<C-x>`).
- A window flag given when imp runs in the terminal (`--tui`, no display, or an imp built without the window) is an error naming the flag, rather than being ignored.
- **Daemon and clients** ([[spec/daemon]]): `--daemon` runs the editor with no client, on a socket; `--connect [FILE...]` attaches a client, the window or, with `--tui` or no display, this terminal; `--connect --via COMMAND` attaches through a command's stdin and stdout; `--bridge` relays stdin and stdout to the local daemon. `--name NAME` picks the socket `NAME.sock` in imp's private socket directory (default `default`), and `--socket PATH` any socket path.
- `--mcp` relays stdin and stdout to the editor's agent socket, for an AI agent to run as its MCP server ([[spec/mcp]]); `--socket PATH` picks another socket.
- `--help` (`-h`) prints the usage and exits; `--version` (`-V`) prints `imp` and the version.
- Any other argument starting with `--` is an error that prints the usage. A flag missing its value is an error naming it.
- **Environment**: `$IMP_GUI_SCALE` is the default `--scale`. `$XDG_CONFIG_HOME` moves `init.scm` (`$XDG_CONFIG_HOME/imp/init.scm`, else `~/.config/imp/init.scm`), and `$XDG_RUNTIME_DIR` holds the sockets (`$XDG_RUNTIME_DIR/imp`, else `/tmp/imp-$USER`).

## Keys and options

| Flag | What it does |
|---|---|
| `--tui` | Run in this terminal |
| `--font FAMILY` | The window's font |
| `--font-file PATH` | Load a font file (repeatable) |
| `--font-size PX` | The window's font size |
| `--scale F` | Multiply the font size (or `$IMP_GUI_SCALE`) |
| `--screenshot OUT.png` | Save the screen as a PNG, with `--grid COLSxROWS` and `--keys KEYS` |
| `--daemon`, `--connect`, `--via COMMAND`, `--bridge` | The daemon and its clients |
| `--name NAME`, `--socket PATH` | Which socket |
| `--mcp` | Relay an agent to the editor's MCP socket |
| `--help`, `--version` | Usage and version |

## Out of scope

- Short forms of the flags, other than `-h` and `-V`, and `--flag=value`.
- Running a command or evaluating Scheme from the command line, as Emacs's `--eval`.
- Opening a file at a line (`+42` or `FILE:42`) from the command line.
- A config file other than `init.scm` named on the command line.

## Known gaps
