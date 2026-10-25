---
type: Page
spec: "[[spec/buffers-and-windows]]"
frozen:
  docs/specs/buffers-and-windows.md: 21bd8d3245c3
---
# Buffers and windows

A buffer is a file, or other text, open in imp. A window shows a buffer, and you can split the screen into as many windows as you like. The commands are Vim's.

## Buffers

Each buffer keeps its own cursor and scroll position. Jumps such as `C-o` cross from one buffer to another.

| Command | What it does |
|---|---|
| `:e FILE` | Open a file |
| `:e!` | Throw away your changes and read the file again |
| `:enew` | Open a new, empty buffer |
| `:ls` | List the buffers |
| `:b NAME` | Switch to a buffer |
| `:bn` / `:bp` | Next or previous buffer |
| `:bd` | Close the buffer |
| `C-^` | Back to the buffer you were in before |
| `:wa` | Save every buffer |
| `:qa` | Quit imp |

`:ls` shortens a long path from the start, so the file name always shows. The status line does the same.

## Splitting windows

`C-w` followed by a key works on windows. `SPC w` does the same from the leader: `SPC w s` splits, `SPC w v` splits side by side.

| Key | What it does |
|---|---|
| `C-w s` | Split the window in two, one above the other |
| `C-w v` | Split it side by side |
| `C-w n` | Split, with a new empty buffer |
| `C-w w` / `C-w W` | Go to the next or previous window |
| `C-w h` `C-w j` `C-w k` `C-w l` | Go to the window left, below, above or right |
| `C-w c` or `C-w q` | Close the window |
| `C-w o` | Close every other window |
| `C-w =` | Make the windows the same size |
| `C-w +` / `C-w -` | Make the window taller or shorter |
| `C-w >` / `C-w <` | Make it wider or narrower |

The same as commands: `:sp` and `:vs` split, and open a file if you name one. `:new` and `:vnew` split with an empty buffer. `:close` closes the window and `:only` keeps just this one. With several windows open, `:q` closes the current one.

A new split goes above, or to the left. Set `splitbelow` or `splitright` to put it below, or to the right, instead.

Each window has its own status line. The bottom row of the screen shows messages, or the command line while you type one.

## Resizing with the mouse

Drag the divider between two windows side by side, or a window's status line, to resize them. In a terminal the divider is one column wide. In the window client, `window-divider-width` sets how many pixels wide it is.

## Popup windows

Some buffers open in a window along an edge of the screen, rather than over what you're working on. `*grep*` opens along the bottom. Git's buffers, `*faces*` and Org's `*capture*` open down the right.

Press `q` to close a popup. A file you open from one, such as a search match, opens in the window you came from. A popup opened from another popup reuses its window.

To choose where a buffer opens, give a rule in `init.scm` with the start of its name:

```scheme
(define-popup-rule! "*grep*" 'side 'right 'size 0.3)
```

## Long lines and line numbers

Long lines wrap onto the next row, as in Vim. Turn on `linebreak` to wrap between words, not in the middle of one. Turn off `wrap` and long lines scroll sideways instead.

Wide characters take two cells, and combining marks take none.

| Option | Shows |
|---|---|
| `number` | Line numbers |
| `relativenumber` | Each line's distance from the cursor |
| `number` and `relativenumber` | The cursor's line number, and distances on other lines |
| `cursorline` | The cursor's line highlighted |
| `signcolumn` | A column for signs, such as diagnostics, before the line numbers |

## Special buffers

Some buffers are made by imp rather than read from a file, such as search results. Press `q` in one to go back to where you were.

To make a buffer read-only, use `:set nomodifiable`.

## Options

| Option | Default | What it does |
|---|---|---|
| `wrap` | `#t` | Wrap long lines onto the next row |
| `linebreak` | `#f` | Wrap between words |
| `number` | `#f` | Show line numbers |
| `relativenumber` | `#f` | Show line numbers relative to the cursor |
| `cursorline` | `#f` | Highlight the cursor's line |
| `signcolumn` | `"auto"` | The sign column: `"yes"` always, `"auto"` while there are signs, `"no"` never |
| `splitbelow` | `#f` | Put a new split below, not above |
| `splitright` | `#f` | Put a new side-by-side split on the right, not the left |
| `window-divider-width` | `0` | Pixels between side-by-side windows in the window client; 0 means one column |
