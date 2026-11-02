---
type: Page
spec: "[[spec/posframe]]"
frozen:
  docs/specs/posframe.md: 9dd5f8aa7b18
---
# Posframe

Posframe draws `M-x`, find-file, switch-buffer and every other pick-from-a-list menu in a box in the middle of the screen, instead of along the bottom. It works as Emacs's vertico-posframe does.

## Turning it on

Posframe is an opt-in package. Load it in your `init.scm`, and it's on:

```scheme
(use-package! 'posframe)
```

Run `M-x posframe-mode` to put menus back along the bottom, and again to bring the box back. The status line says `posframe on` or `posframe off`.

## The box

The box has a rounded border with the prompt's name on top, such as `M-x`. Inside are the line you type on, with a count of the matches, then the list. The cursor is in the box while it's open.

Typing, moving through the list and picking work just as they do at the bottom. Picking or cancelling closes the box.

These stay at the bottom of the screen: the `:` command line, `/` and `?` search, and the which-key popup.

## Making it wider

`posframe-width` is how wide the box is, as a percent of the screen's width:

```scheme
(use-package! 'posframe
  'config (lambda () (set-option! 'posframe-width 80)))
```

A new width applies to the next menu that opens.

## Options

| Command or option | Default | What it does |
|---|---|---|
| `M-x posframe-mode` | | Turn the box off and on |
| `posframe-width` | `60` | How wide the box is, in percent of the screen |
