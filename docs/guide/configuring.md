# Configuring init.scm

Your settings live in `~/.config/imp/init.scm` (or `$XDG_CONFIG_HOME/imp/init.scm`). It's ordinary Scheme, run after the rest of imp loads, so it can change anything. Press `c` on the start screen to open it.

If `init.scm` has an error, imp still starts and shows the error on the status line.

A commented starting point is in the repository: [examples/init.scm](https://github.com/apisandipas/imp/blob/main/examples/init.scm).

## Apply changes without restarting

Edit `init.scm`, then press `SPC e b` to run the whole buffer, or type `:source %`. The change takes effect at once. This works for any Scheme file, not only `init.scm`.

## Options

Set an option with `set-option!`. In the editor, `:set` does the same for the session.

```scheme
(set-option! 'relativenumber #t)
(set-option! 'tabstop 4)
(set-option! 'clipboard "unnamedplus")   ; y and p use the system clipboard
```

`SPC h o` looks up any option: what it does and its current value. `set-local-option!` sets one for the current buffer only.

## Keys

`define-key!` binds a key in a state: `'normal`, `'insert`, `'visual` or `'emacs`.

```scheme
(define-key! 'normal "C-s" 'save-buffer)
(define-key! 'normal "gb" 'switch-buffer "switch buffer")   ; the label shows in the key menu
```

`define-leader!` adds a key to the space menu. Write the keys after `SPC` run together:

```scheme
(define-leader! "fs" 'save-buffer "save file")   ; SPC f s
```

Vim's `:map` commands work too:

```scheme
(run-ex! "inoremap jk <Esc>")
```

To find what a key does now, press `SPC h k` and then the key.

## Commands of your own

A command is a function with a name. It shows in `M-x`, and you can bind it to keys. Its first line, a string, is the description `M-x` and `SPC h f` show.

```scheme
(define-command! 'insert-date
  (lambda (count)
    "Insert today's date at the cursor."
    (begin-change!)
    (buffer-insert! (cursor) (without-final-newline (cadr (run-shell "date +%F" ""))))))

(define-leader! "id" 'insert-date "insert date")
```

Redefining a command changes every key bound to it.

## Hooks

A hook runs your code when something happens. Add a function to one with `add-hook!`:

```scheme
;; Two-space indents in TypeScript and JavaScript.
(add-hook! 'major-mode
  (lambda (mode)
    (when (member mode '(typescript-mode javascript-mode))
      (set-local-option! 'tabstop 2)
      (set-local-option! 'shiftwidth 2))))
```

| Hook | Runs |
|---|---|
| `startup` | Once imp has started |
| `buffer-open` | When a file is opened |
| `buffer-enter` | When you switch to a buffer |
| `major-mode` | When a buffer's mode is set, with the mode |
| `before-save` / `after-save` | Around saving a file |
| `insert-enter` / `insert-leave` | When you enter and leave insert state |
| `mouse-click` | After a left click moves the cursor in a window, with the offset clicked |
| `post-command` | After every command |

`remove-hook!` takes a function off a hook again.

## Changing how imp works

Every part of imp is a Scheme function you can redefine. If you'd rather adjust one than replace it, `advice-add!` runs your code before, after or around it:

```scheme
(advice-add! 'save-buffer 'after (lambda args (message "saved")))
```

`SPC h f` shows any function's docs and where it's defined.

## Themes and faces

imp comes with four themes: `one-dark` (the default), `gruvbox-dark`, `everforest-dark` and `one-light`.

```scheme
(load-theme! 'gruvbox-dark)
```

Make your own from one of them, changing a few colors and faces:

```scheme
(define-theme! 'midnight 'one-dark
  (hash 'bg "#1a1b26" 'blue "#7aa2f7")
  (list (list "syntax.comment" "fg=#565f89 italic")))
(load-theme! 'midnight)
```

To change one face, put the cursor on some text, press `SPC h F` to see its faces, then set one with `set-face!`:

```scheme
(set-face! "syntax.comment" "fg=#7a8478 italic")
```

See [Look](ref-look.md) for fonts, padding and the window's background.

## Next

Add features that don't come switched on: [Packages](packages.md).
