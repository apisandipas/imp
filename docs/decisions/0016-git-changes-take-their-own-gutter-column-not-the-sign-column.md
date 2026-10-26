---
type: Decision
status: accepted
anchors: [packages/git-gutter/git-gutter.scm]
---
# Git changes take their own gutter column, not the sign column

## Context

The gutter already has a sign column (`set-sign-source!`), shared by diagnostics, breakpoints and the debugger's current line. It shows one sign per line, the highest priority one. gitsigns puts git's marks there too, so a line with a diagnostic loses its git mark. VSCode, diff-hl and JetBrains instead draw a thin coloured bar of their own beside the text. The owner chose VSCode's way for #53 ([[git-gutter]]).

## Decision

Git's change marks go in a change column of their own, one cell wide, between the line numbers and the fold column, set with `set-change-marks!`. They aren't a sign source.

## Consequences

- A diagnostic and a git change on the same line both show.
- The gutter has one more column to lay out, and to leave out of mouse clicks on the fold column.
- The column is one cell wide, so it holds a bar, not a two-character sign.
- Anything else that wants a bar by the text can use the change column, but only one thing can own it in a buffer.
