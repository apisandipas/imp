---
type: Page
spec: "[[spec/folding]]"
frozen:
  docs/specs/folding.md: 2596f3a5ab7f
---
# Folding

A fold hides a block of lines behind its first line, so you can see the shape of a file. imp folds code by its indent, and uses Vim's `z` keys to open and close folds.

## Opening and closing folds

A closed fold shows as its first line, with a note of how many lines it hides:

```
fn main() {  ··· 4 lines
```

| Key | What it does |
|---|---|
| `za` | Open or close the fold under the cursor |
| `zo` / `zc` | Open or close it |
| `zA` / `zO` / `zC` | The same for it and every fold inside it |
| `zR` | Open every fold in the buffer |
| `zM` | Close every fold |
| `zj` / `zk` | Go to the start of the next fold, or the end of the one before |

`:foldopen` and `:foldclose` open or close the folds in the lines you give them: `:%foldclose` closes every fold in the file.

`j`, `k` and counts step over a closed fold as one line, and line-wise commands such as `dd` take it whole. A fold opens by itself when you move into it by searching, with a mark, `%`, `{` or `}`, by undoing, or with a sideways motion, as in Vim.

## Which lines fold

`foldmethod` says how imp finds folds. A file starts with `indent`, unless its mode chooses its own: Org folds its headings. Other buffers, and files over 10,000 lines, start with `manual`.

| `foldmethod` | Folds |
|---|---|
| `indent` | Each indented block, with the line above that opens it |
| `syntax` | Each function and class, as the language's parser sees them |
| `expr` | The levels a function you write gives each line |
| `manual` | Only the folds you make |

Set it for one buffer with `:setlocal foldmethod=syntax`.

With `indent`, a line's level is its indent divided by `shiftwidth`. A blank line takes the lower level of the lines around it. The line that opens a block stays in view when it's closed, as in VSCode, rather than folding away as in Vim.

For `syntax`, you can choose which parts of a language fold:

```scheme
(define-syntax-folds! "rust" '("function_item" "impl_item"))
```

For `expr`, give a function that takes a line's number and returns its fold level, a number:

```scheme
(set-local-option! 'foldexpr (lambda (line) level))
```

Folds are worked out again after each change, and when you leave insert state. A fold that's still there stays open or closed as it was. When you set `foldmethod`, folds deeper than `foldlevel` start closed. It's 99 by default, so folds start open.

## Making folds by hand

With `foldmethod` set to `manual`, you make and remove folds yourself. Folds can sit inside other folds.

| Key | What it does |
|---|---|
| `zf` | Fold the lines a motion covers: `zfj` folds this line and the next, `zfap` a paragraph |
| `zF` | Fold a count of lines from this one: `3zF` folds three |
| `zd` | Remove the fold under the cursor |
| `zD` | Remove it and every fold inside it |
| `zE` | Remove every fold in the buffer |

`:fold` folds the lines you give it, such as `:10,20fold`. With another method, these keys say they can't. Setting `foldmethod` back to `manual` keeps the folds it made, as manual ones.

## The fold column

While a buffer has folds, a column appears between the line numbers and the text. It shows `▾` on the first line of an open fold and `▸` on a closed one.

Click a chevron to open or close its fold, as `za` would there. The cursor stays put, unless the fold closes over it. Clicking a blank part of the column does what clicking the line number does.

Set `foldcolumn` to `yes` to always show the column, or `no` to never show it.

## Options

| Option | Default | What it does |
|---|---|---|
| `foldmethod` | `"manual"`; files start with `"indent"` | How folds are found: `manual`, `indent`, `syntax` or `expr` |
| `foldlevel` | `99` | Folds deeper than this start closed when `foldmethod` is set |
| `foldexpr` | `#f` | The function that gives each line's level for `expr` |
| `foldcolumn` | `"auto"` | The fold column: `"auto"` while there are folds, `"yes"` or `"no"` |
