---
type: Page
spec: "[[spec/move-lines]]"
frozen:
  docs/specs/move-lines.md: d4c34470f45d
---
# Move lines

Move lines lets you move whole lines up and down: select them with `V`, then press `J` or `K`. It does what Vim users map `J` to `:m '>+1<CR>gv` for.

## Turning it on

Move lines is an opt-in package. Load it in your `init.scm`:

```scheme
(use-package! 'move-lines)
```

## Moving lines

| Key | What it does |
|---|---|
| `V` | Select lines |
| `J` | Move the selected lines down a line |
| `K` | Move the selected lines up a line |

A count moves them further: `3J` moves them three lines down. The lines stay selected where they land, so you can press `J` or `K` again, or use an operator such as `d` on them.

At the top or bottom of the buffer the lines stop there. Each move is one step to undo with `u`.

Only visual line state changes. With `v` or `C-v`, `J` still joins lines and `K` still looks up the word, as in Vim.

Moved lines aren't re-indented.
