---
type: Page
spec: "[[spec/start-screen]]"
frozen:
  docs/specs/start-screen.md: 3d569d3bf3ea
---
# Start screen

When you start imp without a file, it shows a start screen. From there you can open a recent file, jump into a project, or start typing.

## Opening something

The screen lists your recent files, then your projects, then a few commands. Press the key shown beside an entry to open it, or move to it and press `<ret>`.

| Key | What it does |
|---|---|
| `1` to `9` | Open that recent file |
| `a`, `s`, `d`, `g`, `h` | Find a file in that project |
| `f` | Find a file |
| `r` | Pick from all your recent files |
| `p` | Switch to a project |
| `n` | A new, empty buffer |
| `c` | Open your `init.scm` |
| `?` | Help |
| `q` | Quit |

## Starting to type

Press `i` to leave the start screen and type in the empty buffer. `I`, `A`, `o` and `O` work the same way.

## Getting it back

`:start` shows the start screen again at any time.

To begin in the empty buffer instead, turn the screen off in `init.scm`:

```scheme
(set-option! 'start-screen #f)
```

## Options

| Option | Default | What it does |
|---|---|---|
| `start-screen` | `#t` | Show the start screen when imp starts without a file |
| `recent-files-max` | `100` | How many recent files imp remembers |
