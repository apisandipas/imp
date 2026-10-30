---
type: Effort
status: active
specs: ["[[spec/showkeys]]"]
issue: https://github.com/apisandipas/imp/issues/118
frozen:
  docs/specs/showkeys.md: 8d44499288a6
---
# showkeys

## Approach

The floating box first, in the core, as the one primitive the package can't do without (`packages/CONTEXT.md`): the editor keeps the named boxes, `float-show!` and `float-hide!` set them, and `render.rs` splices each into the screen rows before the popups are drawn, the way `center_popup` splices its box, so popups land over it and both clients get it. Then the package, in Scheme only: advice on `imp-handle-key` sees each key pressed (pasting and macros go around it), a timer hides the box, and options shape what it shows.

## Tasks

- [x] The floating box: `float-show!` and `float-hide!`, the six positions one cell in from the sides and clear of the bottom status lines, the `float.border` face, replaced by name, stacked away from the edge, cut to the screen, under popups and the command line; with tests on the frame's rows.
- [x] The showkeys package: `showkeys-mode`, the last `showkeys-max` keys, hidden after `showkeys-timeout`, key names and symbols with `showkeys-format`, `showkeys-count`, `showkeys-excluded-states`, `showkeys-position`, the `showkeys` faces, only keys pressed; with tests, the reference page, `packages/CONTEXT.md` and the README.
