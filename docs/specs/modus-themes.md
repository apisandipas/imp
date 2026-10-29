---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/57
anchors: [packages/modus-themes/modus-themes.scm, crates/imp-server/tests/modus_themes.rs]
summary: "The modus-themes package: Emacs's Modus Vivendi and Modus Operandi themes, highly legible (WCAG AAA), with their own color for each part of the text, their options, palette overrides and a toggle."
---
# Modus themes

The modus-themes package brings Emacs's Modus themes to imp: Modus Vivendi (white on black) and Modus Operandi (black on white), made by Protesilaos Stavrou to the highest standard of color contrast (WCAG AAA, 7:1). They work like imp's other themes ([[look]]) once the package is loaded.

## Behaviour

- `(use-package! 'modus-themes)` defines two themes, `modus-vivendi` and `modus-operandi`, loaded like any other: `(load-theme! 'modus-vivendi)`, `load-theme` (`SPC t T`), or `:colorscheme`. Switching away from one leaves nothing of it behind.
- **Colors come from Modus itself** (modus-themes 5.3.0): each theme's palette of named colors (`bg-main`, `fg-main`, `fg-dim`, `red`, `red-warmer`, `blue-cooler`, …) and Modus's mapping from what a color is for to the color (`keyword` → `magenta-cooler`, `string` → `blue-warmer`, `comment` → `fg-dim`, `type` → `cyan-cooler`, `constant` → `blue-cooler`, `builtin` → `magenta-warmer`, `docstring` → `green-faint` in Operandi and `cyan-faint` in Vivendi, `fnname` → `magenta`, `property` → `cyan`; numbers, operators and punctuation in the text color). Every imp face takes the color Modus gives the matching thing in Emacs:
  - code: the `syntax.*` faces;
  - the text and frame: `normal`, the cursor line, the region (`visual`), search matches, line numbers, the fold and sign columns, window separators;
  - the status line, active and inactive, and its mode badges;
  - popups, menus, which-key and completion;
  - diagnostics (error, warning, note), diffs and the git status buffer, git blame and the git gutter;
  - Org: headings by level, TODO and DONE, dates, links, checkboxes, code and verbatim;
  - dired, the start screen, and terminal buffers' 16 colors (Modus's `term` colors).
- **New faces** for things the grammars already mark but imp drew alike, so Modus can color them its own way: `syntax.comment.documentation` (docstrings), `syntax.function.builtin` and `syntax.type.builtin` (Modus's `builtin`), and `syntax.constant.builtin`, which the grammars give literals such as `true`, `null` and Rust's numbers, in Modus's `constant` as Emacs colors `true`. In the other themes each one looks as it did: the same as `syntax.comment`, `syntax.function`, `syntax.constant` and `syntax.type`.
- **Bold and italic constructs**, off by default as in Emacs: `(set-option! 'modus-themes-bold-constructs #t)` draws keywords, builtins, types, labels and modules in bold, as Emacs's does; `(set-option! 'modus-themes-italic-constructs #t)` draws comments and docstrings in italic. Changing either redraws a Modus theme that's loaded.
- **Palette overrides**, as in Emacs: an option holds a list of `(name value)` pairs, where name is a named color or a mapping and value is a color (`"#1a1a1a"`) or another name (`magenta`). `modus-themes-common-palette-overrides` applies to both themes; `modus-vivendi-palette-overrides` and `modus-operandi-palette-overrides` to one, and win over the common list. Every face that uses the name follows: `'((keyword red) (bg-main "#111111"))` makes keywords red and the background near-black. Changing one redraws a Modus theme that's loaded. An unknown name is an error naming it.
- **Toggle**: `M-x modus-themes-toggle` switches between Modus Operandi and Modus Vivendi; from any other theme it loads Modus Operandi, as Emacs's does. It has no key; bind one with `define-leader!` or `define-key!`.
- A test checks key faces' colors, in both themes, against the values in the Modus source.

## Out of scope

- The other Modus themes: the tinted, deuteranopia and tritanopia variants.
- Faces for regexp parts (`rx-construct`, `rx-backslash`) and preprocessor directives: no bundled grammar marks them. Nor function definitions apart from calls (`fnname-call`), or variable definitions apart from their uses (`variable`, `variable-use`): the grammars don't tell them apart, so variables stay in the text color, as they are in Emacs by default.
- Modus's other options: mixed fonts, heading sizes and weights (imp's `org-heading-heights` stays), prompt and completion styles.
- Faces for Emacs packages imp has no counterpart of.
