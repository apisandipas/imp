---
type: Page
spec: "[[spec/olivetti]]"
frozen:
  docs/specs/olivetti.md: 5b1ed15a4236
---
# Olivetti

Olivetti keeps a buffer's text in a column of comfortable width in the middle of the window, with blank margins either side, however wide the window is. It's for writing prose, and works as Emacs's olivetti does.

## Turning it on

Olivetti is an opt-in package. Load it in your `init.scm`:

```scheme
(use-package! 'olivetti)
```

Loading it changes nothing yet. Press `SPC t o`, or run `M-x olivetti-mode`, to turn it on in the current buffer, and again to turn it off.

To have it on by itself in some kinds of file, list their major modes in `olivetti-modes`:

```scheme
(use-package! 'olivetti
  'config (lambda ()
            (set-option! 'olivetti-modes '(org-mode markdown-mode))))
```

## The column

The text is `olivetti-body-width` columns wide, 80 unless you change it, centred in every window that shows the buffer. Line numbers stay beside the text. In a window no wider than the column, the text fills the window as usual.

Long lines wrap inside the column, between words. Turning olivetti off puts wrapping back the way it was. To leave wrapping alone, set `olivetti-wrap` to `#f`.

## A wider or narrower column

| Key | What it does |
|---|---|
| `SPC t o` | Turn olivetti on or off in this buffer |
| `C-c }` | Make the column 4 columns wider |
| `C-c {` | Make the column 4 columns narrower |

A count multiplies the step: `3 C-c }` adds 12. The status line says the new width, such as `olivetti: 84 columns`. The column never gets narrower than 20.

The new width is this buffer's own. Other buffers keep `olivetti-body-width`.

## Options

| Option | Default | What it does |
|---|---|---|
| `olivetti-body-width` | `80` | How wide the column is, in columns |
| `olivetti-modes` | `'()` | Major modes whose buffers turn olivetti on when they open |
| `olivetti-wrap` | `#t` | Wrap long lines between words while olivetti is on |
