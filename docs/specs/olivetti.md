---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/135
summary: "The olivetti package: a buffer's text in a centred column of a set width, wrapping between words, for writing prose."
anchors: [packages/olivetti/olivetti.scm, crates/imp-server/tests/olivetti.rs]
---
# Olivetti

A bundled package, after Emacs's [olivetti](https://github.com/rnkn/olivetti), that shows a buffer's text in a column of a set width in the middle of each window, with blank margins either side, however wide the window is. It is for writing prose. It is off until loaded ([[0011-non-essential-features-are-opt-in-packages]]), with `(use-package! 'olivetti)`.

## Behaviour

- Loading it turns nothing on by itself, except in buffers whose major mode is in `olivetti-modes` (none by default): those turn on `olivetti-mode` when they open.
- `olivetti-mode` is a minor mode of the buffer. `M-x olivetti-mode` and `SPC t o` turn it on and off.
- While it is on, the buffer's text is a column `olivetti-body-width` cells wide (default 80), centred in each window that shows it: the blank cells left over are split either side, the line numbers and other gutter columns staying beside the text. A window no wider than the column shows the text as usual. The cursor and mouse clicks follow the text in the column.
- With `olivetti-wrap` on (the default), the mode also turns on `wrap` and `linebreak` in the buffer, so long lines wrap in the column between words. Turning the mode off puts the two options back as they were. With `olivetti-wrap` off, the options are left alone.
- `C-c }` and `C-c {` in normal and visual state make this buffer's column 4 cells wider or narrower, times a count, and say the new width on the status line (`olivetti: 84 columns`). The column is never narrower than 20. The width set this way is the buffer's own and lasts while the buffer does; other buffers keep `olivetti-body-width`.
- Turning the mode off lets the text fill the window again.

## Keys and options

| Key, command or option | Default | What it does |
|---|---|---|
| `SPC t o`, `M-x olivetti-mode` | | Turn the centred column on or off in this buffer |
| `C-c }` / `C-c {` | | Make this buffer's column 4 wider or narrower (count times) |
| `olivetti-body-width` | `80` | The column's width, in cells |
| `olivetti-modes` | `'()` | Major modes whose buffers turn it on when they open |
| `olivetti-wrap` | `#t` | Wrap long lines between words in its buffers |

## Out of scope

- A width as a fraction of the window, as Emacs's olivetti allows.
- Fringes or margins styled differently from the buffer's background.
- Turning it on in every buffer at once.

## Known gaps
