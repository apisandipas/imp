---
status: accepted
issue: https://github.com/apisandipas/imp/issues/75
summary: "The screen imp shows when started without a file: a banner over a short list of actions, minimal and in two colours, each part of which init.scm can change."
anchors: [runtime/start.scm, crates/imp-server/tests/start.rs]
---
# Start screen

A dashboard in the style of Doom Emacs and dashboard-nvim: minimal, a large banner over a few actions, two colours from the theme rather than many.

## Behaviour

- **Shown at start.** Started without a file, imp shows the start screen. `i`, `I`, `A`, `o` and `O` go to the empty buffer; `M-x start-screen` shows it again; `start-screen` off begins in the empty buffer instead.
- **The banner.** "imp" in large block letters, all in the `start.title` face, centred. In a window too narrow or too short for it, a one-line `imp` title shows instead.
- **The actions.** Under the banner, a column of actions, one blank line between each: the label on the left in `start.label`, the key on the right in `start.key`, the keys lined up in a column. To begin with: Recent files `r`, Find file `f`, Switch project `p`, File browser `e`, Search project `/`, Open config `c`, New buffer `n`, Quit `q`. Pressing the key, or `<ret>` on the line, runs it. The cursor starts on the first.
- **The footer.** Below the actions, centred and dimmed (`start.dim`): `imp VERSION`, and `· N packages` when packages are loaded.
- **Sections.** The actions are the `actions` section. `recent-files` (files on `1`-`9`) and `projects` (on `a s d g h`) are sections too, laid out the same way under a dimmed heading, shown when added to `start-sections`.
- **Centred and redrawn.** Everything is centred left and right, the whole a third of the way down; resizing the window redraws it, so the banner comes and goes with the room.
- **Two colours.** The theme's faces: `start.title` and `start.key` in its accent colour, `start.label` its normal text, `start.dim` and headings its comment colour.

### From init.scm

- `(set-option! 'start-banner LINES)`: the banner as a list of strings, or `#f` for the one-line title.
- `(set-option! 'start-sections '(recent-files actions))`: which sections show, in order (`'(actions)` to begin with).
- `(define-start-section! 'NAME "Heading" PROC)` adds a section: `PROC` returns its entries, each `(start-entry KEY LABEL ACTION)`, `ACTION` a command's name or a procedure of no arguments. It shows once `NAME` is in `start-sections`.
- `(define-start-action! KEY LABEL ACTION)` adds an action after the others, replacing any with the same key; `(remove-start-action! KEY)` takes one away.
- `start-recent-files` (9) and `start-projects` (5): how many of each show, at most 9 and 5.
- A key used twice runs the first entry with it; the later one shows without its key.

## Keys and options

`start-screen`, `recent-files-max`, `start-banner`, `start-sections`, `start-recent-files`, `start-projects`. `define-start-section!`, `start-entry`, `define-start-action!`, `remove-start-action!`.

## Out of scope

- A colour per letter or per row in the banner (gradients), and banners that change by day.
- Startup time in the footer.
- An Org agenda section built in; `define-start-section!` can make one.
