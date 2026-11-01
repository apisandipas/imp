---
type: Page
spec: "[[spec/command-line]]"
frozen:
  docs/specs/command-line.md: 552dffb88851
---
# Command line

Everything `imp` takes on its command line: files to open, whether to use a window or the terminal, the window's font, and the daemon.

## Opening files

| Command | What happens |
|---|---|
| `imp` | Opens the start screen |
| `imp notes.txt todo.org` | Opens the files |
| `imp src/` | Opens the file browser on a directory; see [File browser](ref-dired.md) |

## Window or terminal

imp opens a window when there's a display to open it on. Over SSH, on a console, or anywhere else without one, it runs in the terminal you started it from.

`--tui` always uses the terminal, so it's the one to put in `$EDITOR`:

```sh
export EDITOR="imp --tui"
```

If the window can't open after all, imp falls back to the terminal. A stale `$WAYLAND_DISPLAY` inside tmux is the usual cause.

## The window's font and size

| Flag | What it does |
|---|---|
| `--font FAMILY` | The font, such as `--font "JetBrains Mono"` |
| `--font-size PX` | The font size in pixels; 15 unless the `font-size` option says otherwise |
| `--scale F` | Multiplies the font size, for HiDPI screens, such as `--scale 1.5` |
| `--font-file PATH` | Loads a font file that isn't installed, so `--font` can name it. Give it more than once for several files |

`--font` and `--font-size` win over the `font` and `font-size` options in `init.scm`; see [Look](ref-look.md). Setting `IMP_GUI_SCALE` in your environment gives the default for `--scale`.

These flags only mean something to the window. Given one while imp runs in the terminal, imp stops and says so rather than ignoring it.

## Screenshots

`--screenshot` draws imp without a window and saves the screen as a PNG, then exits. It needs no display.

```sh
imp --screenshot shot.png --grid 120x40 --keys 'ihello<esc>' notes.txt
```

`--grid` is the size in columns and rows, `100x30` by default. `--keys` types keys first. Plain characters type themselves; other keys go in angle brackets, as `<esc>`, `<ret>` and `<C-x>`.

## The daemon

| Command | What it does |
|---|---|
| `imp --daemon` | Runs an editor with no window or terminal, on a socket |
| `imp --connect FILE` | Attaches a window or this terminal to it, opening the file |
| `imp --connect --via 'ssh host imp --bridge'` | Attaches to a daemon on another machine |
| `imp --bridge` | Passes its input and output to the daemon here; for `--via` |

`--name NAME` runs or reaches a daemon of that name, for several at once. `--socket PATH` names the socket file itself. See [Daemon](ref-daemon.md).

## AI agents

`imp --mcp` connects an AI agent to a running imp, as its MCP server:

```sh
claude mcp add imp -- imp --mcp
```

imp has to have the agent socket open; see [MCP](ref-mcp.md).

## Other flags

| Flag | What it does |
|---|---|
| `--help`, `-h` | Prints the usage |
| `--version`, `-V` | Prints imp's version |

An unknown flag prints the usage. A flag without its value says which one.

## Environment

| Variable | What it does |
|---|---|
| `IMP_GUI_SCALE` | The default `--scale` |
| `XDG_CONFIG_HOME` | Where `imp/init.scm` is; `~/.config` without it |
| `XDG_RUNTIME_DIR` | Where the daemon's sockets are, in `imp/`; `/tmp/imp-$USER` without it |
