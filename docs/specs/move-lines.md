---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/135
summary: "The move-lines package: J and K move the lines of a visual line selection down and up, keeping them selected."
anchors: [packages/move-lines/move-lines.scm, crates/imp-server/tests/move_lines.rs]
---
# Move lines

A bundled package that moves whole lines up and down, as Vim users map `J` to `:m '>+1<CR>gv` and Emacs users get from drag-stuff. It is off until loaded ([[0011-non-essential-features-are-opt-in-packages]]), with `(use-package! 'move-lines)`.

## Behaviour

- In visual line state (`V`), `J` moves the selected lines down one line and `K` up one line; a count moves them that many lines.
- The moved lines stay selected where they landed, so `J` or `K` again moves them further, and an operator such as `d` acts on them. The cursor stays at the same end of the selection.
- A move stops at the top or bottom of the buffer: lines already there stay put, and a count that would go past moves them only as far as it can.
- Each move is one undo step.
- In character and block visual state, `J` and `K` keep what they did before the package loaded: Vim's join and keyword lookup.

## Keys and options

| Key | State | What it does |
|---|---|---|
| `J` | Visual line | Move the selected lines down (count times) |
| `K` | Visual line | Move the selected lines up (count times) |

## Out of scope

- Moving the current line in normal or insert state without selecting it.
- Moving characters or a block selection left and right.
- Re-indenting the moved lines, as mappings ending in `gv=gv` do.

## Known gaps
