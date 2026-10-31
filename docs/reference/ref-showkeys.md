---
type: Page
spec: "[[spec/showkeys]]"
frozen:
  docs/specs/showkeys.md: 8d44499288a6
---
# showkeys

showkeys shows the last few keys you pressed in a small box in a corner of the screen, so people watching a screencast or a demo can follow along. It works as [nvzone/showkeys](https://github.com/nvzone/showkeys) does in Neovim.

## Turning it on

showkeys is an opt-in package. Load it in your `init.scm`:

```scheme
(use-package! 'showkeys)
```

It loads off. Run `M-x showkeys-mode` to start showing keys, and again to stop.

## What it shows

Each key you press goes on the right of the box, and the box keeps the last three:

```
╭───────╮
│ d i w │
╰───────╯
```

After three seconds without a key, the box goes away and the keys are forgotten. Only keys you press show: text you paste and the keys a macro plays aren't shown.

Keys are written the way imp writes them, `C-x`, `M-x` and `SPC`, with a symbol for a few: `⌫` backspace, `⏎` return, `⇥` tab, `⌦` delete, and `↑ ↓ ← →` for the arrows. Other named keys are spelled out, `Esc` and `Home`.

To show your own text for a key, give `showkeys-format` a list of keys and texts:

```scheme
(set-option! 'showkeys-format '(("<esc>" "⎋") (" " "␣")))
```

With `showkeys-count` on, a key pressed several times in a row shows once, with a count: `j ×4`.

To keep what you type out of the box, leave out insert state:

```scheme
(set-option! 'showkeys-excluded-states '(insert))
```

The `<esc>` that leaves insert state was pressed in it, so it isn't shown either.

## Changing how it looks

The keys are drawn in the `showkeys` face and the border in `showkeys.border`. A theme that doesn't set them gets the floating box's faces below.

```scheme
(set-face! "showkeys" "bold")
```

## Options

| Command or option | Default | What it does |
|---|---|---|
| `M-x showkeys-mode` | | Turn showing keys on and off |
| `showkeys-max` | `3` | How many keys the box shows |
| `showkeys-timeout` | `3` | Seconds with no key before the box hides |
| `showkeys-position` | `'bottom-right` | Where the box goes: `'bottom-` or `'top-`, then `right`, `left` or `center` |
| `showkeys-count` | `#f` | Show a key pressed several times in a row once, with a count |
| `showkeys-excluded-states` | `'()` | States whose keys aren't shown, such as `'(insert)` |
| `showkeys-format` | `'()` | Your own text for keys, as `'(("<esc>" "⎋"))` |

## Floating boxes

A floating box is a few lines in a rounded border at a corner of the screen, or the middle of its top or bottom edge, drawn over your windows. Popups, menus and which-key are drawn over it, and it never takes keys or the cursor. It's there for packages and your own `init.scm`:

```scheme
(float-show! "clock"
             (list (list (list "12:00" "bold")))
             'top-right)
(float-hide! "clock")
```

Each line is a list of `(text face)` runs, as popups take. The positions are `'bottom-right`, `'bottom-left`, `'bottom-center`, `'top-right`, `'top-left` and `'top-center`. A top box starts on the first row; a bottom box ends above the bottom windows' status lines, so they stay readable. Showing a name again replaces its box, and boxes at the same position stack away from the edge.

A box too wide or tall for the screen is cut to fit. Its text is in the `float` face and its border in `float.border`, or the face you pass after the position; a theme that doesn't set them gets the popup's.

| Procedure | What it does |
|---|---|
| `(float-show! name lines position [border])` | Show the box `name`, replacing one of that name |
| `(float-hide! name)` | Remove it |
