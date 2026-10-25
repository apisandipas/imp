---
status: accepted
summary: "Tree-sitter parsing: highlighting, structural text objects, indentation."
anchors: [crates/imp-server/src/syntax.rs, runtime/syntax.scm, crates/imp-server/tests/syntax.rs]
---
# Tree-sitter

Parsing in Rust; what it's used for in Scheme.

## Behaviour

- Bundled grammars: Rust, Scheme, TypeScript and TSX, JavaScript, Nix, Markdown. A major mode names its language.
- Each buffer keeps a parse tree, updated incrementally. Parsing has an 8 ms budget per frame; past that it finishes on a background thread, one per buffer at a time.
- **Highlighting**: the grammar's highlight query runs over the visible rows when drawing. Captures map to faces `syntax.<capture>` with fallback (`syntax.function.method` to `syntax.function`), drawn under diagnostics, search and selection. Where captures overlap, the query's earlier pattern wins, except that of two captures of the same text a more specific one wins over its general one: a Rust doc comment is `comment.documentation`, not the `comment` listed first.
- **Text objects**: `af if` (function), `ac ic` (class), `aa ia` (argument), defined per language from node kinds, working with every operator and visual mode.
- **Indentation**: `smartindent` indents after an opening bracket and dedents a closing one.

## Keys and options

- `(define-mode-language! 'mode "lang")`, `(define-syntax-objects! "lang" function-kinds class-kinds list-kinds)`; primitives `syntax-ancestors`, `syntax-children`, `syntax-tree`.
- `smartindent`, `indent-open`, `indent-close`.

## Out of scope

- Folding from the syntax tree ([[folding]]), and tree-sitter indent queries.
