---
type: Spec
status: accepted
summary: "Typing an opening bracket or quote also types its closing partner, and typing an HTML, XML or JSX start tag closes it."
issue: https://github.com/apisandipas/imp/issues/83
---
# Auto pairs

Typing an opening bracket or quote also types its closing partner, and typing an HTML, XML or JSX start tag closes it, in insert mode and the Emacs state alike, with the pairs set per major mode.

## Behaviour

### Bracket and quote pairs

- **Typing an opener types its closer.** In insert mode, typing `(`, `[`, `{`, `"`, `'` or `` ` `` (those the major mode pairs) inserts the closer after the cursor, which stays between them: `(|)`.
- **Only before a gap.** The closer is added only when the character after the cursor is white space, the end of the line, a closing bracket, or `,` `;` `:` `.`. Typing `(` before `foo` types only `(`.
- **Quotes are pickier.** A quote doesn't pair after a letter or digit (`don't`, `it's`), or inside a string or comment by the syntax tree. With no syntax tree, only the letter-or-digit rule applies.
- **Typing a closer it added steps over it.** Typing `)` when the next character is a `)` that pairing added in this insert moves past it instead of typing a second. A closer that was already in the buffer is typed as usual, as Vim does. A pair is remembered until insert mode ends or the cursor leaves it.
- **Backspace deletes a pair it added.** `<bs>` between an empty pair that pairing added in this insert, `(|)`, deletes both. Any other `<bs>` deletes one character.
- **`<ret>` inside a pair.** With `smartindent`, `<ret>` between `{|}` opens an indented line between them with `}` on the next line, as it does now.
- **Undo and repeat.** The pair is part of the insert, so `u` undoes it with what was typed, and `.` repeats the insert with its pairs.
- **Only typed text.** Text pasted, inserted with `C-r`, or typed in replace mode doesn't pair.

### Pairs per major mode

- Programming modes pair `()`, `[]`, `{}`, `""`, `''` and ` `` `.
- Rust doesn't pair `'`, because of lifetimes (`&'a`).
- Lisp modes (Scheme, Lisp, the REPL) pair `()`, `[]`, `{}` and `""` only. `'` and `` ` `` are quote and quasiquote there.
- Text modes (Markdown, Org, plain text) pair `()`, `[]`, `{}` and `""`. Markdown also pairs ` `` ` for code spans.
- The pairs come from the buffer's major mode, even inside an embedded language (a code fence).

### HTML, XML and JSX end tags

- **Typing a start tag's `>` closes it.** Typing the `>` of `<div class="x">` inserts `</div>` after the cursor, which stays between them.
- **`</` closes the innermost open element.** Typing `/` right after `<` completes `</div>` for the innermost element that has no end tag.
- **Some tags aren't closed.** A self-closing tag (`<x/>`) isn't closed. In HTML files, neither are HTML's void elements (`<br>`, `<img>`, `<input>` and the rest). In XML and SVG files every start tag is closed. An element that already has its end tag isn't closed again.
- **Read from the syntax tree.** Element names come from the tree-sitter tree of the language at the cursor:
  - HTML, XML and SVG files (`html-mode`).
  - A Markdown fence of HTML.
  - JSX elements in JavaScript, JSX and TSX buffers, including fragments (`<>` closes with `</>`).
  - A TypeScript generic such as `f<T>(x)` isn't an element, so it isn't closed.
- **Undo and repeat.** The end tag is part of the insert, as a pair is.

### The Emacs state

- Pairs and tags work the same in the Emacs state (`C-z`) as in insert mode. A pair or end tag undoes with the typing around it, which Emacs groups as it groups self-inserts.
- **Wrapping the region.** In the Emacs state, typing an opener with the region active wraps the region in the pair. The cursor ends after the closer, the region is deactivated, and it undoes in one step. A quote wraps too, even where it wouldn't pair.

## Keys and options

- `auto-pairs` (on by default) turns bracket and quote pairing on or off.
- `auto-pairs-chars` holds the pairs as a string of opener and closer chars, such as `()[]{}""`. Major modes set it locally. Change it per mode or per buffer with `set-local-option!`.
- `auto-close-tags` (on by default) turns end tag closing on or off.
- No new keys.

## Out of scope

- **Wrapping a Vim visual selection.** `(`, `"`, `'`, `[` and `{` are motions or prefixes there. Wrapping waits for a surround feature, like vim-surround's `S`.
- **Balance heuristics.** Emacs's `electric-pair-mode` skips a closer when the buffer is already unbalanced. Here, only the rules above decide.
- **Pairs longer than one character**, such as `/* */`, Python's `"""`, or Org's `~code~` and `=verbatim=`.
- **Renaming the end tag** when the start tag's name is edited (VS Code's linked editing).
- **Tags in Vue, Svelte or template languages**, which imp has no grammars for.
- **Pairs from the embedded language** rather than the buffer's major mode.

## Known gaps
