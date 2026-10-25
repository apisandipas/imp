---
type: Effort
status: active
specs: ["[[spec/modus-themes]]"]
frozen:
  docs/specs/modus-themes.md: 1e594e46b053
---
# Modus themes package

## Approach

Issue #57. A package, `packages/modus-themes/modus-themes.scm`, holds the two Modus 5.3.0 palettes as they are in the source: named colors, and mappings whose value is a color or another name. A resolver follows names to a hex color, after applying the palette overrides. From the resolved palette the package builds each theme with `define-theme!`: imp's own palette slots (bg, fg, red, …) filled from Modus's, so any face not listed still gets a sensible color, plus a full list of faces in Modus's colors, read off the Emacs faces Modus defines for the same things. When an option changes, the package rebuilds both themes and reloads the one in use.

The four new syntax faces aren't defined by the other themes: a capture's face falls back to the general face when the specific one doesn't exist (render.rs), so they keep looking as they did, and a user's `set-face!` on the general face still covers them. For that to survive switching from a Modus theme, `load-theme!` removes the faces the last theme set that the new one doesn't.

## Tasks

- [x] Core: `load-theme!` removes the faces the last theme set that the new one doesn't (a `remove-face!` primitive), so a theme can set the four new faces (`syntax.comment.documentation`, `syntax.function.builtin`, `syntax.constant.builtin`, `syntax.type.builtin`) and the other themes, which don't, keep drawing them as their general face; with tests; the look spec says so
- [x] The package, registered in `PACKAGES`: both palettes from the source, the resolver, and the two themes with the code and frame faces (normal, cursor line, region, search, line numbers, columns, separators, syntax); a test checks those faces' hex values against the source
- [x] The rest of the faces: status line and mode badges, popups, menus, which-key and completion, diagnostics, diffs, git, blame and gutter, Org, dired, the start screen, terminal colors; tests for a sample of each
- [x] `modus-themes-bold-constructs` and `modus-themes-italic-constructs`, redrawing a loaded Modus theme, with tests
- [x] Palette overrides (common and per theme, per theme winning), redrawing, an unknown name an error naming it, with tests
- [x] `modus-themes-toggle`, with a test
- [x] Screenshots of the same files in both themes, compared with Modus's published samples, and fixes
- [x] The reference page `ref-modus-themes.md` (docs-page skill) in the docs' groups, the Packages guide and `packages/CONTEXT.md` list it, the spec's anchors
- [ ] The owner has looked at both themes
