# Phase 1 design: daily-driver Vim

Written at the start of the phase; updated as decisions change. The roadmap
items are in `docs/HANDOFF.md` §6. Owner decisions that shape this phase:
styled frames (3.3) are pulled forward so visual mode and search can
highlight; `regex` crate for search; `wl-copy`/`wl-paste` for the clipboard.

## Order

1. Linewise range cleanup (prerequisite, see below).
2. Text objects (1.1).
3. Styled frames (3.3, pulled forward).
4. Visual mode (1.2).
5. Search and `:s` (1.3).
6. Motions (1.4), commands (1.5), registers (1.6), macros (1.7), undo polish
   (1.8), marks and jumps (1.9), ex polish and `:eval` (1.10).

## Linewise ranges

Today `motion-range` returns, for a linewise range that reaches the last line,
the line break *before* the first line instead of after the last one, so the
file keeps its final newline. That is right for `d` but wrong for `c` (`cc` on
the last line ate the previous line break) and awkward for every future
linewise operator (`>`, `gu`, visual `V`).

New rule: a linewise range is always whole lines, `line-start(first)` up to
`line-start(last + 1)` or the end of the buffer. Only `d` knows about the
final-newline special case. Operators therefore receive one consistent shape.

## Text objects

A text object is `(lambda (from count) (list start end linewise?))`, or `#f`
when there is nothing to select (Vim beeps; we leave the buffer alone). They
live in a table like motions:

    (define-text-object! "iw" proc)

In operator-pending mode `i` and `a` become prefix keys, so `diw` looks up
`"iw"`. Visual mode will use the same table to extend the selection. Dot-repeat
records `(lambda (n) (run-text-object! op key n))`, the same as motions.

Covered: `iw aw iW aW`, `i" a" i' a' i\` a\``, `i( a( ib ab i) a)`,
`i[ a[ i] a]`, `i{ a{ iB aB i} a}`, `i< a< i> a>`, `it at`, `ip ap`.
Semantics follow Vim: `aw` takes trailing white space, or leading white space
if there is none; quotes are found on the cursor's line only and `a"` takes
trailing white space; `i{` on a block whose braces sit on their own lines is
linewise over the inner lines; `ip` counts blank-line runs as paragraphs.

## Styled frames

The frame protocol moves from rows of plain strings to rows of styled spans:

    Frame { rows: Vec<Vec<Span>>, cursor, cursor_shape }
    Span  { text: String, style: Style }
    Style { fg, bg: Option<Color>, bold, italic, underline, reverse }

Rust owns rendering and the face table. Scheme decides what is highlighted:

- `(set-face! name spec)`: spec is a string such as `"fg=#ff8800 bg=#202020
  bold"`, parsed in Rust. Faces are looked up by name when rendering, so
  redefining a face restyles everything that uses it.
- `(highlight-set! layer ranges)` / `(highlight-clear! layer)`: a layer (a
  string such as `"visual"` or `"search"`) holds `(start end face)` triples
  in char offsets. Layers are drawn in a fixed order, later layers over
  earlier ones; syntax highlighting (Phase 4) becomes one more layer.

The client maps `Style` to crossterm attributes. Diffing frames is still later
work (3.3 proper); full redraw stays for now.

## Visual mode

State in Scheme: `*visual*` is `#f`, `'char` or `'line` (block later), with
`*visual-anchor*` an offset. The cursor is the other end. Every key in visual
mode recomputes the `"visual"` highlight layer. Motions move the cursor;
text objects extend the selection; operators act on the selection and leave
visual mode; `o` swaps ends; `gv` restores the last selection. Visual
operations are dot-repeatable over the same size of region, as in Vim.

## Search

A Rust primitive `(buffer-search pattern from forward?)` returns the offset of
the next match (wrapping) or `#f`; `(buffer-search-all pattern)` returns match
ranges for highlighting; `(buffer-replace-in-line ...)`-style helpers only if
`:s` in pure Scheme proves too slow. Pattern syntax is the `regex` crate's,
with Vim's `\<`/`\>` translated to `\b`. Smartcase as in Vim with `ignorecase
smartcase`, since that's what most Vim users configure.

## Outcome

Built as designed, with these differences and additions:

- **Rust primitives added for speed**, after measuring with
  `examples/bench.rs`: `find-open`, `find-close` and `tag-pairs-around`
  (bracket and tag text objects took 0.6-1 s on 100k lines from Scheme; now
  ~8 ms and ~1 ms). Everything else stayed in Scheme and runs in ~0.1-0.3 ms
  per key on that file.
- **Motions can fail** by returning `#f`. That cancels an operator, stops a
  macro, and lets `j`/`k`/`h`/`l` fail at edges as Vim's do.
- **Char motions and char commands** (`f`, `r`, `m`, `q`, `@`, `"`) are
  prefixes; `fx` resolves to a motion on the fly, so it composes with
  everything without extra code.
- **Registers** are `(text type)` where type is `#f` (chars), `#t` (lines)
  or `'block`.
- **Marks live in the Rust buffer** so they move with edits; the jump list
  is a list of mark names.
- **The command line** replaces the status row while typing (`set-cmdline!`)
  instead of being drawn into the status text, so it has a real cursor.
- **Popups** (`set-popup!`) show multi-line output (`:marks`, `:reg`) above
  the status line until the next key; which-key (2.4) will reuse them.
- **Options** (`define-option!`, `:set`) were needed earlier than planned,
  for `shiftwidth` and friends.
- Visual-mode `:` and ex ranges use the `<`/`>` marks, as in Vim.
