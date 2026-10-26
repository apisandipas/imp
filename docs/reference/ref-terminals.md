---
type: Page
spec: "[[spec/terminals]]"
frozen:
  docs/specs/terminals.md: 7b43584e6e0e
---
# Terminals

A terminal runs your shell, or any program, in a buffer. You type to the program, then step out to search and copy its output like any other text.

## Opening a terminal

Press `SPC o t`, or type `:terminal`, to run your shell in a new buffer. `:terminal CMD` runs a program instead:

```
:terminal htop
```

The buffer keeps the program's output, up to 10,000 lines, in the program's colors. The first sixteen colors come from your theme.

When the program exits, `[process exited N]` shows at the end and the buffer stays open.

## Typing to the program

A new terminal starts in the TERMINAL state. Every key goes to the program, even `<esc>` and `:`.

| Key | What it does |
|---|---|
| `C-\ C-n` | Leave for normal state |
| `i` `a` `I` `A` | In normal state, go back to typing to the program |

In normal state the output is ordinary text. Search it, move around it, and yank from it as you would in any buffer.

To keep a key for imp while you're typing to the program, give it to `define-terminal-key!` in `init.scm` with a function of no arguments. That key no longer reaches the program.

## Size

A terminal fits the windows showing it. When it's in more than one, it takes the smallest height and width among them, as in Neovim. It resizes when you split, close or resize a window.

## The mouse

Some programs, such as `less`, `htop` and `vim`, ask for the mouse. In the TERMINAL state, clicks, drags and the wheel in their window go to them. Otherwise the mouse works as in any buffer.

## Pasting

| Key | Where it works | What it does |
|---|---|---|
| `S-<insert>` or `C-S-v` | The window client | Paste the system clipboard |
| `Cmd-v` | The window client on macOS | Paste the system clipboard |

In the terminal client, your terminal's own paste works, and the text arrives whole. `C-v` keeps its Vim meanings in both clients.

Where the paste goes depends on the state:

- In the TERMINAL state, it goes to the program.
- In insert state, it's inserted as it is, with no autoindent.
- In normal and visual state, it's inserted at the cursor as one change, so one `u` undoes it.
- On the command line, it's typed there, with line breaks as spaces.

If imp can't read the clipboard, nothing is pasted and a message says so. There's no middle-click paste of the selection in the window client.
