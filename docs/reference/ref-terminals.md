---
type: Page
spec: "[[spec/terminals]]"
frozen:
  docs/specs/terminals.md: 127f6a0b5b15
---
# Terminals

A terminal runs your shell, or any program, in a buffer. You type to the program, then step out to search and copy its output like any other text.

## Opening a terminal

Press `SPC o T`, or type `:terminal`, to run your shell in a new buffer in the current window. `:terminal CMD` runs a program instead:

```
:terminal htop
```

Give it a name, or another directory to start in, with `++` options before the command:

```
:terminal ++name=build ++cwd=~/src/imp cargo watch
```

A relative `++cwd=` is taken from the current buffer's directory. If a buffer has the name already, the new one gets `<2>` after it. Without a command, it runs your shell.

The buffer keeps the program's output, up to 10,000 lines, in the program's colors. The first sixteen colors come from your theme.

When the program exits, `[process exited N]` shows at the end and the buffer stays open.

## Finding a terminal

Press `SPC o l`, or run `M-x switch-terminal`, to pick from your terminals. Beside each name are its command (`shell` for your shell), its directory, and `exited` once its program has. The terminal you pick comes up in the TERMINAL state if its program is running. A toggled terminal, like the project's, comes up in its own window.

## Closing a terminal

Killing a terminal stops its program, so imp asks first while one is running, as it does for unsaved changes:

- `:bd` refuses, and `:bd!` kills it.
- `SPC b k` (or `SPC b d`, or `C-x k`) asks "kill the program running in NAME? (y or n)".
- `:q`, `:qa`, `:wq`, `:x` and `C-x C-c` refuse, take you to the terminal and say so. Add `!` to quit anyway.

Once the program has exited, the buffer goes without asking. `SPC a k` stops Claude without asking.

In a daemon, `:q` only detaches your client and the terminals keep running, for the next client. `M-x kill-server` stops them, so it asks.

To stop asking, turn the option off everywhere, or run `set-local-option!` in one terminal's buffer:

```scheme
(set-option! 'terminal-confirm-kill #f)
```

## The project's terminal

Press `SPC o t`, or `` M-` `` from anywhere, to bring up your project's own shell in a window down the right. The first time, the shell starts in the project root. Press the same key inside it to hide it again. The shell keeps running while it's hidden, so it comes back as you left it, mid-command and all.

Each project has its own. Buffers outside any project share one, in imp's current directory. A project can have more than one: `2 SPC o t` brings up its second, `*terminal: PROJECT<2>*`, starting it the first time. Without a count you get the one you showed last, and `` M-` `` and `SPC o s` use that one too. `1 SPC o t` goes back to the first. If you `exit` the shell, the next toggle starts a new one. The buffer is named `*terminal: PROJECT*`, after the project's directory. Kill it and the shell stops.

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
| `gz{motion}` | What the motion or text object covers: `gzap` a paragraph, `gzip` without its blank line |
| `gzz` | The current line |
| `gz` | In visual mode, the selection |

The terminal starts if it isn't running and comes up if it's hidden. The cursor stays in your buffer. Sending the line moves the cursor to the next line, so `SPC o s` again sends that one. Visual mode ends after sending. `gz` is an operator like `d` or `y`, so `.` sends the same again from where the cursor is now.

The text arrives as one paste, as your terminal's own paste does, with a final line break dropped. Then imp presses `<ret>` to run it. To have it wait for your `<ret>` instead, turn that off:

```scheme
(set-option! 'terminal-send-enter #f)
```

A shell that's still starting gets the text once it has printed its prompt. Claude has its own sending keys, on [its page](ref-claude.md).

## The shell's directory

A terminal knows its directory: where it started, and then wherever you `cd`, if your shell reports it. From a terminal buffer:

- `find-file` lists the files of that directory's project, or under the directory outside one.
- `:e NAME` opens a relative `NAME` from there, and `<tab>` completes there.
- `:Ex` opens the file browser there.
- `:terminal` and `SPC o T` start the new terminal there.
- The project is that directory's. The project's own terminal stays its project's, so `SPC o t` still hides it.

The directory stays after the program exits.

Shells report their directory with an escape sequence, OSC 7. fish sends it already. bash and zsh don't, so add this to your `~/.bashrc`:

```bash
PROMPT_COMMAND='printf "\e]7;file://%s%s\e\\" "$HOSTNAME" "$PWD"'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

or to your `~/.zshrc`:

```zsh
_osc7() { printf '\e]7;file://%s%s\e\\' "$HOST" "$PWD" }
precmd_functions+=(_osc7)
```

A report from another machine, from a shell you `ssh`'d into, is ignored, so the directory stays the last one on this machine.

## Prompts

If your shell marks its prompts, in normal state you can move by command and pick out one command's output:

| Key | What it does |
|---|---|
| `]]` / `[[` | Go to the next or previous prompt |
| `io` | The output of the command the cursor is in, as whole lines: `yio` yanks it, `gzio` sends it to the project's terminal |
| `ao` | The same with its prompt and command |

Each prompt gets a `›` in the sign column, or a `✗` after a command that failed.

Shells mark prompts with an escape sequence, OSC 133. bash and zsh don't send it by default, so add these lines. In `~/.bashrc`, after setting `PS1` and after the directory line above, so `$?` is still the command's status:

```bash
PS0='\e]133;C\a'
PROMPT_COMMAND='printf "\e]133;D;%s\a\e]133;A\a" "$?"'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
PS1=$PS1'\[\e]133;B\a\]'
```

In `~/.zshrc`, after setting `PS1`:

```zsh
_osc133_precmd() { print -n "\e]133;D;$?\a\e]133;A\a" }
_osc133_preexec() { print -n "\e]133;C\a" }
precmd_functions=(_osc133_precmd $precmd_functions)
preexec_functions+=(_osc133_preexec)
PS1=$PS1$'%{\e]133;B\a%}'
```

Marks go with their lines when the history, 10,000 lines, scrolls them away.

## The program's title

When the program sets a title, as `vim`, `htop` and many shells do, it shows dimmed after the buffer's name in the status line, and beside the name in `switch-buffer`. The buffer keeps its name, so popup rules still find it. An empty title clears it, and the last one stays after the program exits.

In your own `statusline`, `%{title}` puts it where you like.

## Copying from a program

Programs that copy with OSC 52, such as `nvim`, `tmux` or a shell over `ssh`, copy to your clipboard as `"+y` does: on the clipboard, and in the unnamed register, so `p` pastes it. The message line says how much was copied, and from which terminal. A copy to the primary selection goes to `"*`.

It's the clipboard of the machine imp runs on, so with `--via` it's the server's. Programs can't read the clipboard this way. To stop them copying:

```scheme
(set-option! 'terminal-clipboard #f)
```

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
