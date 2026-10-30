---
type: Page
spec: "[[spec/terminals]]"
frozen:
  docs/specs/terminals.md: 01ca620df0d2
---
# Terminals

A terminal runs your shell, or any program, in a buffer. You type to the program, then step out to search and copy its output like any other text.

## Opening a terminal

Press `SPC o T`, or type `:terminal`, to run your shell in a new buffer in the current window. `:terminal CMD` runs a program instead:

```
:terminal htop
```

The buffer keeps the program's output, up to 10,000 lines, in the program's colors. The first sixteen colors come from your theme.

When the program exits, `[process exited N]` shows at the end and the buffer stays open.

## The project's terminal

Press `SPC o t`, or `` M-` `` from anywhere, to bring up your project's own shell in a window down the right. The first time, the shell starts in the project root. Press the same key inside it to hide it again. The shell keeps running while it's hidden, so it comes back as you left it, mid-command and all.

Each project has its own. Buffers outside any project share one, in imp's current directory. If you `exit` the shell, the next toggle starts a new one. The buffer is named `*terminal: PROJECT*`, after the project's directory. Kill it and the shell stops.

Popups on the same side share a window, so bringing up the terminal while [Claude](ref-claude.md) is showing puts it in Claude's window. Claude keeps running hidden. To put the terminal somewhere else, change its popup rule:

```scheme
(define-popup-rule! "*terminal:" 'side 'bottom 'size 0.3)
```

### A toggle of your own

`define-toggled-terminal!` gives any program the same toggle. It takes the command's name, what to run (a string, or an option holding one), and the start of its buffer's name for its popup rule:

```scheme
(define-toggled-terminal! 'lazygit "lazygit" "*lazygit")
(define-popup-rule! "*lazygit" 'side 'right 'size 0.5)
(define-leader! "gl" 'lazygit "lazygit")
```

Now `SPC g l`, or `M-x lazygit`, shows the project's lazygit, and hides it again. To hide it from the TERMINAL state with one key, add `(define-terminal-key! "M-g" (lambda () (run-command 'lazygit)))`.

## Sending text to the terminal

Send code from a file to run in your project's terminal:

| Key | What it sends |
|---|---|
| `SPC o s` | The selection in visual mode, or the current line in normal state |
| `SPC o b` | The whole buffer |

The terminal starts if it isn't running and comes up if it's hidden. The cursor stays in your buffer. Sending the line moves the cursor to the next line, so `SPC o s` again sends that one. Visual mode ends after sending.

The text arrives as one paste, as your terminal's own paste does, with a final line break dropped. Then imp presses `<ret>` to run it. To have it wait for your `<ret>` instead, turn that off:

```scheme
(set-option! 'terminal-send-enter #f)
```

A shell that's still starting gets the text once it has printed its prompt. Claude has its own sending keys, on [its page](ref-claude.md).

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
