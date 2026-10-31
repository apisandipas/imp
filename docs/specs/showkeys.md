---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/118
anchors: [packages/showkeys/showkeys.scm, crates/imp-server/tests/showkeys.rs, crates/imp-server/tests/float.rs]
summary: "The showkeys package shows the last few keys you pressed in a small box in a corner of the screen, for screencasts, on a floating box the core draws over the windows."
---
# showkeys

A bundled package, after [nvzone/showkeys](https://github.com/nvzone/showkeys), that shows the keys you press as you press them, in a small bordered box in a corner of the screen, so people watching a screencast or a demo can follow along. It draws on a floating box, a primitive the core adds for it.

## Behaviour

### The floating box (core)

- `(float-show! name lines position [border])` shows a bordered box named `name` (a string) holding `lines`, each a list of `(text face)` runs as popups take. `position` is one of `'bottom-right`, `'bottom-left`, `'bottom-center`, `'top-right`, `'top-left`, `'top-center`; any other is an error. Showing a name again replaces its box; `(float-hide! name)` removes it.
- The box is as wide as its widest line plus a space either side, inside a rounded border. The text is over the `float` face, and the border is in the face `border` names, or `float.border`; a theme that sets neither gets the popup's and the popup border's. It is drawn one cell in from the screen's side edges. A top box starts on the screen's first row; a bottom box ends on the row above the bottom windows' status lines, so they stay readable.
- It is drawn over the windows, in the terminal and the window client alike, and under popups, menus, which-key and the command line. It takes no keys and never has the cursor.
- A box wider or taller than the screen is cut to fit. Boxes at the same position stack away from the edge, in the order their names were first shown.

### The package

- `(use-package! 'showkeys)` loads it, off. `M-x showkeys-mode` turns it on and off.
- While it's on, each key pressed is added on the right of the box, and the box shows the last `showkeys-max` keys (default 3), separated by spaces, older ones dropping off the left. A key a pasted text or a macro replays isn't shown; only keys pressed are.
- After `showkeys-timeout` seconds (default 3) with no key, the box hides and the keys are forgotten. Turning it off hides the box at once.
- Keys are shown as imp names them (`C-x`, `M-x`, `SPC`), with a symbol for a few: `<bs>` ⌫, `<ret>` ⏎, `<tab>` ⇥, `<del>` ⌦, `<up>` ↑, `<down>` ↓, `<left>` ←, `<right>` →. Other named keys lose their brackets and are capitalised (`<esc>` is `Esc`, `<home>` is `Home`). `showkeys-format`, an association list from key to text, replaces any of these.
- With `showkeys-count` on (off by default), a key pressed again right after itself isn't shown twice: the last key gets a count, `j ×4`.
- A key pressed in one of `showkeys-excluded-states` (none by default; `'(insert)` hides what is typed) isn't shown. The state is the one the key was pressed in, so the `<esc>` that leaves insert mode counts as insert.
- `showkeys-position` (default `'bottom-right`) is where the box goes.
- The keys are in the `showkeys` face, the border in `showkeys.border`; by default the floating box's.

## Keys and options

| Command or option | Default | What it does |
|---|---|---|
| `M-x showkeys-mode` | | Turn showing keys on and off |
| `showkeys-max` | `3` | How many keys the box shows |
| `showkeys-timeout` | `3` | Seconds with no key before the box hides |
| `showkeys-position` | `'bottom-right` | Where the box goes: bottom- or top-, right, left or center |
| `showkeys-count` | `#f` | Show a repeated key once, with a count |
| `showkeys-excluded-states` | `'()` | States whose keys aren't shown, e.g. `'(insert)` |
| `showkeys-format` | `'()` | Key to text, replacing how a key is shown |

## Out of scope

- The command each key ran, as Emacs's keycast shows: left out to keep the package small.
- Mouse clicks and scrolling, pasted text, and keys a macro or mapping replays.
- Recording keys to a file, or a history to scroll back through.
- Floating boxes that take keys or the cursor, or that sit anywhere but a corner or the middle of an edge.

## Known gaps
