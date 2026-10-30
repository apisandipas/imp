---
type: Effort
status: active
specs: ["[[spec/start-screen]]"]
issue: https://github.com/apisandipas/imp/issues/75
frozen:
  docs/specs/start-screen.md: 3a63b6f3dc40
---
# A minimal start screen

## Approach

`start.scm` keeps its drawing on `draw-line!`, but builds the screen from sections, each a list of `(key label action)` entries: `actions` by default, `recent-files` and `projects` on request. The banner is six lines of block letters, dropped for a one-line title when the window lacks room. A new `resize` hook, run by the server when the client's screen changes size, redraws the screen if it is showing. The faces go to two colours from the palette: the accent for the banner and keys, the normal text for labels, the comment colour for the footer and headings.

## Tasks

- [ ] The look: the banner (or the one-line title when it doesn't fit), the actions with keys in a column and a blank line between, the footer with the version and packages, `recent-files` and `projects` as sections, the cursor on the first entry, a redraw on resize through a new `resize` hook, and the faces in two colours. Tests, the reference page, and an everforest-dark screenshot.
- [ ] From init.scm: `start-banner`, `start-sections`, `define-start-section!` and `start-entry`, `define-start-action!` and `remove-start-action!`, `start-recent-files` and `start-projects`, a key used twice running the first. Tests and the page.
