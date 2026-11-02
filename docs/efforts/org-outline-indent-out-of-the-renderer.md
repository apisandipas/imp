---
type: Effort
status: done
specs: ["[[spec/org]]", "[[spec/buffers-and-windows]]"]
issue: https://github.com/apisandipas/imp/issues/132
frozen:
  docs/specs/org.md: 3a958ecfb511
  docs/specs/buffers-and-windows.md: bc8c82b25ab1
---
# Org outline indent out of the renderer

Org's org-indent is drawn by Rust: `heading_level`, `outline_prefix` and `outline_hidden_stars` in `render.rs` know that a heading is leading stars and a space and do org-indent's arithmetic, and `set-outline-indent!` is a primitive only Org uses, against [[0005-rust-owns-data-and-speed-scheme-owns-behavior]]. `outline_prefix` also looks back up to 5,000 lines for the heading above every drawn line, every frame. A refactor: what a user sees stays the same.

## Approach

One general primitive takes Org's place: `set-line-prefixes!` gives the current buffer's lines blank cells before their text, on every row they wrap to (Emacs's `line-prefix` and `wrap-prefix`, which Emacs's org-indent sets). It takes `(line cells)` pairs, each for its line and the lines after it up to the next pair's, so a section is one pair, not one per line; Rust keeps them in a sorted map and finds a line's prefix with one lookup, which ends the 5,000-line scan. The renderer's drawing, wrap and scrolling read it where they read `outline_prefix`. ("Prefix", not "indent": `line-indent` is already Vim's indent of a line, in `vim.scm`.)

`org.scm` finds the headings (`search-all`), works out the prefixes and sets them, so the heading rule lives only in Scheme. Setting them all again after every change was measured first and is too slow: 50 to 60 ms a keystroke that adds or removes a line, on the bench's file with 10,000 headings, Steel taking about half a microsecond an operation. So the prefixes move with their lines in Rust as the text is edited, the way marks do (`Editor::sync_line_prefixes`, from the buffer's change log), and after a change Org sets only the lines it changed and the one after, with `put-line-prefixes!`, carrying on from the line above (`line-prefix-width`). An edit then costs the lines it touched. An undo or redo isn't in the change log edit by edit, so after one Org sets them all.

A heading's stars but the last are drawn in `org.hide` by a buffer highlight pattern, `^\(\*\+\)\* `, which follows edits for nothing. For that a buffer layer's pattern paints what its groups match, or the whole match when it has none, as a conceal pattern already hides; Org's patterns with groups for alternation are wrapped in one more group, so they paint as before. Global patterns (the search highlight) still paint the whole match, as Vim's hlsearch does. Highlight ranges would not do: they don't follow edits, so every keystroke would have to set them all again.

Measured with `examples/bench.rs`, which gains Org cases: a 100,000-line Org file with org-indent on, its headings 10 lines apart and 2,000 apart.

## Tasks

- [x] The bench times commands on a 100,000-line Org file with org-indent, headings dense and sparse; the numbers before the change go in the PR.
- [x] A buffer layer's highlight pattern paints its groups' matches, or the whole match without groups, with a test; Org's patterns paint as before.
- [x] `set-line-prefixes!` (in `api/display.rs`) sets the current buffer's line prefixes, and drawing, wrap, scrolling and clicks use them, with a render test; `org.scm` sets the prefixes and the hidden-star pattern itself, and `set-outline-indent!`, `Editor::outline_indents`, `heading_level`, `outline_prefix` and `outline_hidden_stars` are gone. The org-indent test and the indented-section click test pass unchanged.
- [x] Line prefixes move with their lines as the text is edited, and Org sets only the lines a change touched (`put-line-prefixes!`, `line-prefix-width`), with tests that adding and deleting lines and headings keeps every prefix right; the bench's numbers after go in the PR.

## Notes

- The hidden stars are now drawn in `org.hide` over the heading's face. Before, `s.over(org.hide)` let the heading's colour win, so the stars org-indent meant to blank were drawn in the heading's colour.
- An undo in a buffer with org-indent sets every prefix again: about 28 ms on the bench's file with 10,000 headings, 2 ms with 50. Undo resets the buffer's change log; logging its edits would make it as cheap as any other edit.
