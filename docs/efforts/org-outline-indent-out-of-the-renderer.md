---
type: Effort
status: active
specs: ["[[spec/org]]", "[[spec/buffers-and-windows]]"]
issue: https://github.com/apisandipas/imp/issues/132
frozen:
  docs/specs/org.md: 3a958ecfb511
  docs/specs/buffers-and-windows.md: bc8c82b25ab1
---
# Org outline indent out of the renderer

Org's org-indent is drawn by Rust: `heading_level`, `outline_prefix` and `outline_hidden_stars` in `render.rs` know that a heading is leading stars and a space and do org-indent's arithmetic, and `set-outline-indent!` is a primitive only Org uses, against [[0005-rust-owns-data-and-speed-scheme-owns-behavior]]. `outline_prefix` also looks back up to 5,000 lines for the heading above every drawn line, every frame. A refactor: what a user sees stays the same.

## Approach

One general primitive takes Org's place: `set-line-indents!` gives the current buffer's lines blank cells before their text, on every row they wrap to (Emacs's `line-prefix` and `wrap-prefix`, which Emacs's org-indent sets). It takes `(line columns)` pairs, each indenting its line and the lines after it up to the next pair's, so a section is one pair, not one per line; Rust keeps them in a sorted map and finds a line's indent with one lookup, which ends the 5,000-line scan. The renderer's drawing, wrap and scrolling read it where they read `outline_prefix`.

`org.scm` finds the headings (`search-all`), works out the indents and sets them, so the heading rule lives only in Scheme. It sets them again after a change, but only when the change could move them: when the line count changed or a changed line's heading level did. Typing in a section's text then costs a line or two, not a scan of the buffer.

A heading's stars but the last are drawn in `org.hide` by a buffer highlight pattern, `^\(\*\+\)\* `, which follows edits for nothing. For that a buffer layer's pattern paints what its groups match, or the whole match when it has none, as a conceal pattern already hides; Org's patterns with groups for alternation are wrapped in one more group, so they paint as before. Global patterns (the search highlight) still paint the whole match, as Vim's hlsearch does. Highlight ranges would not do: they don't follow edits, so every keystroke would have to set them all again.

Measured with `examples/bench.rs`, which gains Org cases: a 100,000-line Org file with org-indent on, its headings 10 lines apart and 2,000 apart.

## Tasks

- [x] The bench times commands on a 100,000-line Org file with org-indent, headings dense and sparse; the numbers before the change go in the PR.
- [x] A buffer layer's highlight pattern paints its groups' matches, or the whole match without groups, with a test; Org's patterns paint as before.
- [ ] `set-line-indents!` (in `api/display.rs`) sets the current buffer's line indents, and drawing, wrap, scrolling and clicks use them, with a render test; `org.scm` sets the indents and the hidden-star pattern itself, and `set-outline-indent!`, `Editor::outline_indents`, `heading_level`, `outline_prefix` and `outline_hidden_stars` are gone. The org-indent test and the indented-section click test pass unchanged.
- [ ] Org sets the indents again after a change only when headings or the line count changed, with a test that typing a heading or a new line updates the indent; the bench's numbers after go in the PR, and `crates/imp-server/CONTEXT.md` names the shared layout as it now is.
