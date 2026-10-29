---
type: Page
spec: "[[spec/emacs-state]]"
frozen:
  docs/specs/emacs-state.md: b74c1fe8672a
---
# Emacs state

If your hands know Emacs, imp has an Emacs state beside Vim's. In it, keys you type go into the text, and the usual Emacs keys move and edit.

## Switching between Vim and Emacs

Press `C-z` to switch from Vim to Emacs state, and `C-z` again to switch back. It works from normal, insert and visual state.

To start in Emacs state every time, set `editing-style` in `init.scm`:

```scheme
(set-option! 'editing-style "emacs")
```

## Moving

| Key | What it does |
|---|---|
| `C-f` / `C-b` | Forward or back a character |
| `C-n` / `C-p` | Down or up a line |
| `C-a` / `C-e` | Start or end of the line |
| `M-f` / `M-b` | Forward or back a word |
| `M-<` / `M->` | Start or end of the buffer |

## The mark, the region and the kill ring

Press `C-SPC` to set the mark. The text between the mark and the cursor is the region.

| Key | What it does |
|---|---|
| `C-k` | Kill to the end of the line |
| `C-w` | Kill the region |
| `M-w` | Copy the region |
| `C-y` | Yank the last kill |
| `M-y` | Right after `C-y`, swap in the kill before it |
| `C-d` / `M-d` | Delete a character, or kill a word |

Kills also go to Vim's unnamed register, so `p` in Vim state pastes them.

Typing a bracket or quote with the region active wraps the region in the pair, as `electric-pair-mode` does. Without a region, brackets and quotes pair as they do in insert mode. See [Auto pairs](ref-auto-pairs.md).

Typing a bracket or quote with the region active wraps the region in the pair, as `electric-pair-mode` does. Without a region, brackets and quotes pair as they do in insert mode. See [Auto pairs](ref-auto-pairs.md).

## Searching, undo and commands

| Key | What it does |
|---|---|
| `C-s` / `C-r` | Search forward or back as you type; press again for the next match |
| `C-/` | Undo |
| `C-g` | Quit what you're doing and drop the region |
| `M-x` | Run a command by name |
| `C-u` | Give the next command an argument, as in Emacs |

## The C-x keys

| Key | What it does |
|---|---|
| `C-x C-s` | Save the buffer |
| `C-x C-f` | Find a file |
| `C-x b` | Switch buffer |
| `C-x k` | Kill a buffer |
| `C-x C-c` | Quit imp |

## Adding your own keys

Bind more keys in `init.scm` with `define-key!`. Write the keys as Emacs does, with spaces between them:

```scheme
(define-key! 'emacs "C-x C-s" 'save-buffer)
```

imp doesn't run Elisp or Emacs's own packages.

## Options

| Option | Default | What it does |
|---|---|---|
| `editing-style` | `"vim"` | The state imp starts in: `"vim"` or `"emacs"` |
