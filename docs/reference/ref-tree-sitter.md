---
type: Page
spec: "[[spec/tree-sitter]]"
frozen:
  docs/specs/tree-sitter.md: b388bc7bc1c2
---
# Tree-sitter

imp reads the structure of your code with tree-sitter. That gives it syntax colors, text objects for functions, classes and arguments, and indentation after brackets. It keeps up as you type, even in large files.

## Languages

imp comes with grammars for Rust, Scheme, TypeScript and TSX, JavaScript, Nix, Markdown, HTML, CSS, JSON, YAML, TOML, Bash (for shell scripts), C, Go, Python and Lua. Each major mode names the grammar it uses. C++, Elixir and Ruby files have their modes (`cpp-mode`, `elixir-mode`, `ruby-mode`) and text objects, but no bundled grammar, so they aren't highlighted yet; installing grammars at runtime is still to come. HTML's grammar also reads XML and SVG files, and CSS's reads SCSS. To parse another mode with one of these, name it in `init.scm`:

```scheme
(define-mode-language! 'lisp-mode "scheme")
```

A grammar you built yourself, as a shared library, can be used the same way. Register it with the library's path and the directory of its `highlights.scm` (and `injections.scm`, if it has one). The library is loaded the first time a buffer or a code fence uses the language:

```scheme
(register-grammar! "ruby" "/path/to/ruby.so" "/path/to/tree-sitter-ruby/queries")
```

It works like a bundled grammar: modes, aliases, text objects and code fences all use it, and one with a bundled grammar's name takes its place. If the library won't load, because it has no `tree_sitter_ruby` function or was built for a tree-sitter imp can't read, the message line says so and the buffer is plain.

## Syntax colors

Each kind of thing in the code, such as a keyword or a function name, is drawn in its own face. The faces are named `syntax.` and the kind: `syntax.keyword`, `syntax.function`, `syntax.function.method`. A face that isn't set falls back to the shorter name, so `syntax.function.method` looks like `syntax.function` unless you set it. A few grammars use older names, such as `conditional` and `method`; those fall back to the current names' faces, `syntax.keyword` and `syntax.function`.

Change one with `set-face!`:

```scheme
(set-face! "syntax.keyword" "fg=#e67e80 bold")
```

Diagnostics, search matches and the selection are drawn over the syntax colors. See [Look](ref-look.md) for themes and faces.

## Embedded languages

Code in another language inside a file is colored as that language: JavaScript in an HTML `<script>` and CSS in a `<style>`, over HTML's own colors. In Markdown, a fenced code block is colored in the language after its opening fence, YAML (`---`) or TOML (`+++`) front matter as YAML or TOML, and the inline syntax in paragraphs and headings (emphasis, strong, code spans, links) in the `syntax.text.*` faces. Other grammars embed languages too: a Rust macro's body is colored as Rust, a Nix build phase or `writeShellScript` string as Bash, a JavaScript tagged template (`` css`…` ``, `` html`…` ``) as its tag's language, and LuaJIT's `ffi.cdef` as C. Embedded languages nest, so an HTML block in a Markdown fence has its `<script>` colored as JavaScript, up to four levels deep. It keeps up as you type, like the rest of the file. Text objects and indentation follow the file's own language, not the embedded one.

A fence's language is matched by grammar name, then by alias, ignoring case. The common aliases come built in: `js`, `ts`, `sh`, `shell`, `zsh`, `py`, `rs`, `yml`, `md`, `htm`, `xml`, `scm` and more. Add your own in `init.scm`:

```scheme
(define-language-alias! "snek" "python")
```

A block in a language imp has no grammar for (Ruby's `rb`, say, since Ruby isn't bundled) is drawn as Markdown draws code, with no message.

## Queries

A language's colors come from its highlights query, and the languages embedded in it from its injections query. A bundled grammar uses its crate's queries, and a grammar you registered uses the `highlights.scm` and `injections.scm` in its queries directory. To change them for any language, put your own in imp's config directory, as `queries/NAME/highlights.scm` or `queries/NAME/injections.scm`. Yours replaces the language's own, for files opened after imp starts.

A query can build on others. If its first comment lines include `; inherits: javascript,jsx`, those languages' queries, found the same way, come before it. A language inherited twice is included once, and a language that inherits back is left out, so a cycle stops:

```scheme
; inherits: rust
((identifier) @variable.builtin (#eq? @variable.builtin "self"))
```

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
