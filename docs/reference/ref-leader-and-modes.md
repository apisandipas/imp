---
type: Page
spec: "[[spec/leader-and-modes]]"
frozen:
  docs/specs/leader-and-modes.md: f86f363277a8
---
# Leader and modes

Press space in normal or visual state to reach most of imp's commands, with a popup to show you the way. Each buffer also has a mode, picked from its file name, that sets how it's indented, commented and which keys it adds.

## The leader key

`SPC` starts a key sequence, much as in Doom Emacs. The keys are grouped by what they do:

| Keys | Group |
|---|---|
| `SPC f` | Files |
| `SPC b` | Buffers |
| `SPC e` | Evaluating Scheme |
| `SPC h` | Help |
| `SPC s` | Search |
| `SPC t` | Toggles |
| `SPC w` | Windows |
| `SPC q` | Quit |
| `SPC m` | The current major mode's own keys |

For example, `SPC f f` finds a file and `SPC w v` splits the window to the right.

## The which-key popup

Pause after `SPC` and a popup lists the keys that can come next and what each does. It updates as you type, so you can learn the tree by looking. `which-key-delay` sets how long it waits.

Press `<bs>` to go back a level: `SPC g <bs>` shows the `SPC` popup again. At `SPC` alone, `<bs>` closes it, as `<esc>` does.

Vim's prefix keys show the same popup: `g`, `z`, `Z`, `[`, `]` and `C-w`. Its title is what you've typed so far, count included, such as `3g`. It lists only keys that do something here, including the buffer's mode keys. Typing the next key closes it.

There's no popup after `"`, after `f` and the other character motions, or after an operator such as `d`.

## Major and minor modes

Each buffer has one major mode, picked by its file name when it opens. imp has major modes for about 20 languages. Each sets the indentation and how comments are written.

`:mode rust` switches the buffer to another major mode, and `:mode` alone says which one it's in.

A buffer can also have any number of minor modes. Keys from minor modes win over the major mode's, and the major mode's win over the usual keys.

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

`define-mode-leader!` adds a key under `SPC m` for one major mode. `define-mode-key!` binds a key for one mode in one state:

```scheme
(define-mode-key! 'lua-mode 'normal "K" 'describe-function "describe")
```

The last argument, the label, is what which-key shows. `define-key!`, `define-motion!` and `define-operator!` take one too.

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
