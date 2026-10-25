---
status: accepted
summary: "Themes, faces, the status line, popups, window appearance and text heights."
anchors: [runtime/theme.scm, crates/imp-server/tests/theme.rs, crates/imp-server/tests/heights.rs]
---
# Look

## Behaviour

- **Themes** make every face from a palette: `one-dark` (default), `gruvbox-dark`, `everforest-dark`, `one-light`, through `:theme` or `SPC t T`. `define-theme!` takes a parent. A `normal` face lies under everything. Switching themes removes the faces the last theme set and the new one doesn't, so nothing of it is left behind. Text in a face that doesn't exist is drawn in its general face: `syntax.function.builtin`, `syntax.constant.builtin`, `syntax.type.builtin` and `syntax.comment.documentation` exist only in themes that color them apart, such as the Modus themes ([[modus-themes]]), and are `syntax.function`, `syntax.constant`, `syntax.type` and `syntax.comment` in the others.
- **Faces**: `describe-face` (`SPC h F`) and `list-faces`. Terminal ANSI colors 0-15 come from the theme.
- **Status line**: a Vim-style format string per window (`%m %f %M %l %c %L %p %{name} %#face# %* %=`), with a colored mode badge, file, modified dot, diagnostics counts, major mode, position and percent; values drop first when narrow, and long paths shorten from the start.
- **Popups**: which-key and menus under a titled rule with colored keys; LSP completion and hover in a bordered box at the cursor.
- **Window appearance**: `font`, `font-size`, `window-padding`, `window-divider-width`, `background-opacity`, `terminal-background`. Command-line `--font` and `--font-size` win over the options. The terminal, with `terminal-background` off, sends no background for `normal` cells.
- **Text heights**: a face can say `height=1.3`; the window client draws lines as tall as their tallest face. Org headings use it ([[org]]).

## Keys and options

`statusline`, `statusline-inactive`, and the appearance options above. `(define-theme! 'name 'parent palette extra-faces)`, `(load-theme! 'name)`, `set-face!` with specs like `"fg=#ff8800 bg=blue bold height=1.2"`.
