---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/135
summary: "The posframe package: M-x, find-file and every other completing-read menu in a bordered box in the middle of the screen."
anchors: [packages/posframe/posframe.scm, crates/imp-server/tests/posframe.rs]
---
# Posframe

A bundled package, after Emacs's [vertico-posframe](https://github.com/tumashu/vertico-posframe), that draws completion menus in a bordered box across the middle of the screen instead of along the bottom. It is off until loaded ([[0011-non-essential-features-are-opt-in-packages]]), with `(use-package! 'posframe)`.

## Behaviour

- Loading it turns it on.
- While it is on, every menu that asks you to pick from a list (`completing-read`: `M-x`, find-file, switch-buffer, the describe commands and the rest, [[spec/completion]]) opens in a box centred across the screen, `posframe-width` percent of the screen's width (default 60) inside its rounded border. The box's top border carries the prompt's name; inside it, the prompt line with what you type and the match count, a rule, then the menu. The cursor is in the box's prompt line, and the bottom line of the screen stays empty.
- Typing, moving through the menu and picking work as they do at the bottom. Picking or cancelling closes the box.
- Other prompts stay where they were: the `:` command line, `/` and `?` search, and the which-key popup.
- `M-x posframe-mode` turns it off, putting menus back along the bottom, and on again, and says which on the status line (`posframe on`, `posframe off`).
- A new `posframe-width` applies to the next menu that opens.

## Keys and options

| Command or option | Default | What it does |
|---|---|---|
| `M-x posframe-mode` | | Turn the centred box off and on |
| `posframe-width` | `60` | The box's width, in percent of the screen's |

## Out of scope

- A box placed anywhere but the middle, or sized by its contents.
- The `:` line or search in the box.

## Known gaps
