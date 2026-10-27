---
type: Page
spec: "[[spec/tree-sitter]]"
frozen:
  docs/specs/tree-sitter.md: c9c187a5e3d9
---
# Tree-sitter

imp reads the structure of your code with tree-sitter. That gives it syntax colors, text objects for functions, classes and arguments, and indentation after brackets. It keeps up as you type, even in large files.

## Languages

imp comes with grammars for Rust, Scheme, TypeScript and TSX, JavaScript, Nix, Markdown, HTML, CSS, JSON, YAML, TOML, Bash (for shell scripts), C, C++, Go and Python. Each major mode names the grammar it uses. HTML's grammar also reads XML and SVG files, and CSS's reads SCSS. To parse another mode with one of these, name it in `init.scm`:

```scheme
(define-mode-language! 'lisp-mode "scheme")
```

## Syntax colors

Each kind of thing in the code, such as a keyword or a function name, is drawn in its own face. The faces are named `syntax.` and the kind: `syntax.keyword`, `syntax.function`, `syntax.function.method`. A face that isn't set falls back to the shorter name, so `syntax.function.method` looks like `syntax.function` unless you set it.

Change one with `set-face!`:

```scheme
(set-face! "syntax.keyword" "fg=#e67e80 bold")
```

Diagnostics, search matches and the selection are drawn over the syntax colors. See [Look](ref-look.md) for themes and faces.

## Text objects

These work with every operator, such as `d`, `c` and `y`, and in visual mode:

| Keys | What they select |
|---|---|
| `af` / `if` | The function around the cursor, or only its body |
| `ac` / `ic` | The class or type around the cursor, or only its body |
| `aa` / `ia` | The argument or parameter at the cursor, with or without its comma |

For example, `dif` empties the function's body, and `cia` changes one argument.

Each language says which parts of its tree are functions, classes and argument lists. Set them for a language with `define-syntax-objects!`, giving the node kinds for functions, for classes, and for lists whose items are arguments:

```scheme
(define-syntax-objects! "nix"
  '("function_expression")              ; functions
  '("attrset_expression")               ; classes
  '("formals" "list_expression"))       ; argument lists
```

`:syntax-tree` shows the current buffer's tree, to find the node kinds.

## Indentation

With `smartindent` on, a new line after an opening bracket is indented one level. Typing a closing bracket at the start of a line takes the indent back. imp turns it on in code buffers, except Scheme and Lisp.

Indentation doesn't use tree-sitter's indent rules. Folding by the syntax tree is part of [Folding](ref-folding.md).

## Options

| Option | Default | What it does |
|---|---|---|
| `smartindent` | `#f` | Indent after an opening bracket and dedent a closing one |
| `indent-open` | `"{[("` | The brackets that indent the next line |
| `indent-close` | `"}])"` | The brackets that dedent their line |
