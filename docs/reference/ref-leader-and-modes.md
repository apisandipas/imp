---
type: Page
spec: "[[spec/leader-and-modes]]"
frozen:
  docs/specs/leader-and-modes.md: 039e08ed9d0b
---
# Leader and modes

Press space in normal or visual state to reach most of imp's commands, with a popup to show you the way. Each buffer also has a mode, picked from its file name, that sets how it's indented, commented and which keys it adds.

## The leader key

`SPC` starts a key sequence, much as in Doom Emacs. The keys are grouped by what they do:

| Keys | Group |
|---|---|
| `SPC a` | Claude Code |
| `SPC b` | Buffers |
| `SPC c` | Code: language server actions |
| `SPC d` | Debugging |
| `SPC e` | Evaluating Scheme |
| `SPC f` | Files |
| `SPC g` | Git |
| `SPC h` | Help |
| `SPC o` | Org and terminals; `SPC o a` is the Org agenda |
| `SPC p` | Projects |
| `SPC q` | Quit |
| `SPC s` | Search |
| `SPC t` | Toggles |
| `SPC w` | Windows |
| `SPC m` | The current major mode's own keys |

For example, `SPC f f` finds a file and `SPC w v` splits the window to the right.

A few keys work straight after `SPC`:

| Keys | What it does |
|---|---|
| `SPC SPC` or `SPC .` | Find a file |
| `SPC ,` | Switch buffer |
| `SPC :` | Run a command by name, as `M-x` does |
| ``SPC ` `` | Go back to the last buffer |

## The which-key popup

Pause after `SPC` and a popup lists the keys that can come next and what each does. It updates as you type, so you can learn the tree by looking. `which-key-delay` sets how long it waits.

Press `<bs>` to go back a level: `SPC g <bs>` shows the `SPC` popup again. At `SPC` alone, `<bs>` closes it, as `<esc>` does.

A count typed before `SPC` goes to the command: `2 SPC o t` brings up your project's second terminal.

Vim's prefix keys show the same popup: `g`, `z`, `Z`, `[`, `]` and `C-w`. Its title is what you've typed so far, count included, such as `3g`. It lists only keys that do something here, including the buffer's mode keys. Typing the next key closes it.

There's no popup after `"`, after `f` and the other character motions, or after an operator such as `d`.

## Major and minor modes

Each buffer has one major mode, picked by its file name when it opens. imp has major modes for about 20 languages. Each sets the indentation and how comments are written.

`M-x set-major-mode` switches the buffer to another major mode: pick one, or type part of its name (`:set-major-mode rust`). The current mode is first in the list, so pressing `<ret>` straight away says which one it's in.

A buffer can also have any number of minor modes. Keys from minor modes win over the major mode's, and the major mode's win over the usual keys.

## Which key wins

A key can be bound in several places: by the buffer's modes and by Vim. In normal and visual state, imp runs the first of these that binds the key:

| State | Order |
|---|---|
| Normal | The buffer's mode keys, then Vim's operators, motions, normal keys, and keys that take a character (`r`) |
| Visual | The buffer's mode keys, then visual keys, operators, text objects, keys that take a character, and motions |

The mode keys are the minor modes' keys first, then the major mode's and the modes it builds on, then your `:map` mappings. A mode key can also take over a count digit, `/`, `?`, or a prefix such as `g` or `z`. That is how the start screen's `1` opens a recent file, `?` in git status lists its keys, and `q` closes special buffers.

After an operator such as `d`, only a motion, a text object or the operator again (`dd`) counts. The buffer's mode keys don't apply there.

Which-key, `describe-key` and `:map` follow the same order. So what they tell you about a key is what it would do in this buffer: `d` in git status is its diff menu, not Vim's delete.

## Commenting

`gc` with a motion comments or uncomments lines, using the mode's comment style. `gcc` does the current line, and `gc` in visual state does the selected lines.

To set the comment style yourself, set `commentstring`, with `%s` where the text goes:

```scheme
(set-local-option! 'commentstring "-- %s")
```

## Adding your own keys

Add a leader key, and name a group so the popup shows it:

```scheme
(define-leader-group! "x" "extras")
(define-leader! "xr" 'recent-files "recent files")
```

`define-mode-leader!` adds a key under `SPC m` for one major mode, and `define-mode-leader-group!` names a group of them, as `(define-mode-leader-group! 'org-mode "c" "clock")` shows `c → +clock`. `define-mode-key!` binds a key for one mode in one state:

```scheme
(define-mode-key! 'lua-mode 'normal "K" 'describe-function "describe")
```

The last argument, the label, is what which-key shows. `define-key!`, `define-motion!` and `define-operator!` take one too.

To see which binding a key would run, call `resolve-key` with the state and the key, and an operator to ask about a key after it:

```scheme
(resolve-key 'normal "d")       ; in git status, its diff menu
(resolve-key 'normal "w" "d")   ; the motion dw uses
```

It returns `#f` for a key that does nothing.

Mode keys that start with a control or meta key, such as `C-c C-c`, wait for the rest of the sequence. They work in normal, visual and insert state, without getting in the way of `g`, `z` or typing. A mode can also bind keys that start with a letter, such as the agenda's `ct`: there, in normal state, `c` waits for the next key instead of starting a Vim change.

## Making your own modes

Define a major mode with the mode it builds on, its file extensions, and what to set in its buffers:

```scheme
(define-major-mode! 'lua-mode 'prog-mode '("lua")
  (lambda () (set-local-option! 'shiftwidth 2)))
```

`define-file-name-mode!` picks a mode by a whole file name, such as `Makefile`. `define-minor-mode!` defines a minor mode, and `minor-mode-on!` turns it on in the current buffer. `set-major-mode!` switches the current buffer's major mode.

## Options

| Option | Default | What it does |
|---|---|---|
| `which-key-delay` | `300` | Milliseconds before the which-key popup shows |
| `commentstring` | `"# %s"` | How a comment is written; each major mode sets its own |
