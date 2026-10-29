---
type: Page
spec: "[[spec/auto-pairs]]"
frozen:
  docs/specs/auto-pairs.md: 96385e7355d2
---
# Auto pairs

In insert mode, typing an opening bracket or quote types its closing partner too, with the cursor between them. Type what goes inside, then the closer, and the cursor steps past the one already there.

## Typing a pair

Typing `(`, `[`, `{`, `"`, `'` or `` ` `` gives `(|)`, where `|` is the cursor. The closer is only added when there's room for it: before white space, at the end of the line, before a closing bracket, or before `,` `;` `:` `.`. Typing `(` just before `foo` types only `(`, since you're probably about to wrap it.

A quote doesn't pair straight after a letter or digit, so `don't` and `it's` type as usual. Nor does it pair inside a string or a comment, where you're more likely typing an apostrophe or closing the string. That needs the buffer's language to have a syntax tree; without one, only the letter-or-digit rule applies. Brackets pair in strings and comments too.

Pasted text, a register inserted with `C-r`, and text typed in replace mode (`R`) never pair.

## Stepping over and deleting

| You type | With | You get |
|---|---|---|
| `)` | `(x|)`, the `)` added by a pair | `(x)|`, stepping over it |
| `<bs>` | `(|)`, a pair just added | `|`, both gone |
| `<ret>` | `{|}`, with `smartindent` | `{`, an indented line for the cursor, then `}` |

This only applies to closers that a pair added in the current insert. A `)` that was already in the file is typed as Vim types it, and `<bs>` beside it deletes one character. A pair is forgotten when you leave insert mode or move the cursor out of it.

The pair is part of the insert: `u` undoes it with the text you typed, and `.` types it again.

## Pairs in each mode

| Mode | Pairs |
|---|---|
| Programming languages | `()` `[]` `{}` `""` `''` and backticks |
| Rust | the same, without `''`, which would get in the way of lifetimes (`&'a`) |
| Scheme, Lisp and the REPL | `()` `[]` `{}` `""`; `'` and backtick are quote and quasiquote |
| Org and plain text | `()` `[]` `{}` `""` |
| Markdown | `()` `[]` `{}` `""` and backticks, for code spans |

A code block in Markdown or Org uses the file's own pairs, not the pairs of the language inside it.

## Options

| Option | Default | What it does |
|---|---|---|
| `auto-pairs` | on | Whether brackets and quotes pair at all |
| `auto-pairs-chars` | the mode's | Each opener followed by its closer, as in `()[]{}""`; a quote is its own closer |

Set them in `init.scm`, or for the current buffer only with `set-local-option!`. Setting `auto-pairs-chars` in `init.scm` gives every mode the same pairs:

```scheme
(set-option! 'auto-pairs #f)                    ; no pairing anywhere
(set-local-option! 'auto-pairs-chars "()[]{}")  ; brackets only, in this buffer
```
