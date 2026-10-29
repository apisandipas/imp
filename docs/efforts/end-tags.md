---
type: Effort
status: planned
specs: ["[[spec/auto-pairs]]"]
issue: https://github.com/apisandipas/imp/issues/83
frozen:
  docs/specs/auto-pairs.md: 96385e7355d2
---
# End tags

## Approach

The second half of [[spec/auto-pairs]], after [[bracket-and-quote-pairs]]. Element names come from the syntax tree, but `syntax-ancestors` only sees the buffer's own language, so a new Rust function, `syntax-at`, gives the innermost language at an offset (an embedded one inside a fence or `<script>`) and its nodes there. The tag code lives in `runtime/syntax.scm` with the other tree-sitter features. That file loads after `vim.scm` and `emacs.scm`, so they call it through a variable set with `set!` (`*typed-char-handler*`), run after a plain char is typed in insert mode or the Emacs state, as `*insert-key-handler*` does for keys. The end tag goes in with `buffer-insert!` during the key, so undo and `.` take it with the insert, as pairs do. Whether an element "already has its end tag" is read from the tree. Typing `<div>` inside an existing `<div></div>` makes the parser hand the `</div>` to the new element, so the build checks that case with a test before choosing the rule.

## Tasks

- [ ] `syntax-at`: the innermost language at an offset and its named nodes around it, innermost first, as `syntax-ancestors` gives them: Markdown's inside a paragraph, HTML's inside a fence of HTML, JavaScript's in a `<script>`. Rust and Scheme tests, and the Languages line of `runtime/CONTEXT.md`.
- [ ] `>` closes an HTML start tag: in `html-mode`, typing the `>` of `<div class="x">` inserts `</div>` after the cursor. Not for a self-closing tag (`<x/>`), HTML's void elements in `.html` files, or an element that already has its end tag; in `.xml` and `.svg` files every start tag closes. The `auto-close-tags` option (on). Works in insert mode and the Emacs state; `u` undoes it with the insert and `.` repeats it. Tests, and an end tags section in `docs/reference/ref-auto-pairs.md`.
- [ ] `</` closes the innermost open element: typing `/` right after `<` completes `</div>` for the innermost element with no end tag; with none open, just `/`. Tests.
- [ ] A Markdown fence of HTML closes tags as an HTML file does, through `syntax-at`; outside the fence, `<` and `>` are plain. Tests.
- [ ] JSX: in JavaScript, JSX and TSX buffers, a JSX element's `>` closes it, a fragment `<>` closes with `</>`, and `</` closes the innermost one; a TypeScript generic (`f<T>(x)`) and a comparison aren't closed. Tests, and the page says so.
