---
status: accepted
summary: "Tree-sitter parsing: highlighting (embedded languages included), structural text objects, indentation, and grammars bundled or installed at runtime."
anchors: [crates/imp-server/src/syntax.rs, runtime/syntax.scm, crates/imp-server/tests/syntax.rs]
---
# Tree-sitter

Parsing in Rust; what it's used for in Scheme.

## Behaviour

- Bundled grammars: Rust, Scheme, TypeScript and TSX, JavaScript, Nix, Markdown, HTML, CSS, JSON, YAML, TOML, Bash, C, Go, Python and Lua, each with its crate's highlight query, always in the binary. A major mode names its language: `html-mode` (`.html`, `.htm`, `.xml`, `.svg`) uses HTML, `css-mode` (`.css`, `.scss`) CSS, `shell-mode` Bash, and the rest their own.
- C++, Elixir and Ruby aren't bundled: they would be two-thirds of what the grammars add to the binary, for fewer people, who can install them at runtime. Their modes are: `cpp-mode` names `cpp`, and new modes `elixir-mode` (`.ex`, `.exs`) and `ruby-mode` (`.rb`, `.rake`, `Rakefile`, `Gemfile`) name `elixir` and `ruby`, with their text objects defined, so an installed grammar of that name highlights and has text objects with nothing else to set. Until then those buffers aren't parsed.
- **Grammars at runtime**: `(define-grammar! "name" "git-url" "rev")`, with an optional fourth argument for a grammar in a subdirectory of the repository, declares a grammar. M-x `install-grammars` installs every declared grammar that isn't built at its declared revision, and M-x `install-grammar` asks for one of the declared grammars, each shown as built or not at its revision, and installs (or rebuilds) it. Installing clones the repository with `git` into `$XDG_DATA_HOME/imp/grammars/` (`~/.local/share/imp/grammars/`), checks out the revision, and compiles its `src/parser.c` and any `src/scanner.c` or `src/scanner.cc` with `$CC` (else `cc`, and `c++` for a C++ scanner) into a shared library there. It runs in the background, saying in the message line what it's doing and when each grammar is done or failed. Without `git` or a C compiler it fails with a message naming what's missing.
- A built grammar loads the first time a buffer uses its language, and from then on works like a bundled one: `define-mode-language!` names it, and it highlights and has text objects. A runtime grammar with the same name as a bundled one takes its place. Opening a buffer whose language is declared but not built shows a message saying to run M-x `install-grammars`, and the buffer has no highlighting; nothing is cloned or built unasked. A grammar that fails to load (built for an incompatible tree-sitter version, say) says so in the message line, and the buffer goes without it.
- A grammar's source is fully trusted code. Installing one compiles its `scanner.c` (arbitrary C) from the repository `define-grammar!` names, and loading a grammar library, installed or `register-grammar!`ed, runs its native code inside imp, with all of imp's access, and nothing sandboxes it.
- **Highlight queries**: a runtime grammar's is the repository's `queries/highlights.scm` (in the grammar's subdirectory if it has one). For any language, bundled or not, `queries/NAME/highlights.scm` in imp's config directory replaces it. A query whose first lines include `; inherits: a,b` gets the queries of languages `a` and `b` (bundled or runtime, theirs resolved the same way) put before it; a language inherited twice is included once, and a cycle stops.
- Each buffer keeps a parse tree, updated incrementally. Parsing has an 8 ms budget per frame; past that it finishes on a background thread, one per buffer at a time.
- **Highlighting**: the grammar's highlight query runs over the visible rows when drawing. Captures map to faces `syntax.<capture>` with fallback (`syntax.function.method` to `syntax.function`), and a capture still named as Neovim named it before (`conditional`, `repeat`, `field`, `method`, `parameter`, `preproc`, `delimiter`) falls back to its current name's faces (`syntax.keyword.conditional`, then `syntax.keyword`), drawn under diagnostics, search and selection. Where captures overlap, imp follows tree-sitter's own highlighter: the narrower one wins, so TOML's number inside a pair captured as a whole is a number, and of two captures of exactly the same text the query's later pattern wins, so a Rust doc comment is `comment.documentation`, not the `comment` listed before it, and YAML's keys are `property`. Queries combined from several files (TypeScript's and TSX's with JavaScript's) are joined in the order the grammar's own setup lists them.
- **Embedded languages**: a grammar's injections query says which parts of a buffer are in another language, and those are parsed with that language's grammar and highlighted with its query, over the outer language's highlighting. JavaScript in an HTML `<script>` and CSS in `<style>` are, and a Markdown fenced code block is in the language its info string names. Markdown's inline syntax (emphasis, code spans, links) is tree-sitter-md's inline grammar, embedded the same way. Embedded languages nest: a Markdown fence of HTML has its `<script>` highlighted as JavaScript. Injected regions are parsed incrementally and within the same parse budget, finishing in the background past it.
- An embedded language's name (`js`, `py`, `sh`) is matched against grammar names and then aliases. `(define-language-alias! "alias" "language")` adds one, and the common ones are bundled: `js`, `ts`, `sh`, `shell`, `zsh`, `py`, `rb`, `ex`, `exs`, `c++`, `yml`, `md`, `htm` and `scm`, among others. A language no grammar matches, or a declared grammar not built yet, is left as the outer language draws it, with no message.
- Injection queries come from the same places as highlights: the bundled crate's, a runtime grammar repository's `queries/injections.scm`, or `queries/NAME/injections.scm` in imp's config directory instead, with `; inherits:` resolved the same way. A language with no injections query embeds nothing.
- **Text objects**: `af if` (function), `ac ic` (class), `aa ia` (argument), defined per language from node kinds, working with every operator and visual mode.
- **Indentation**: `smartindent` indents after an opening bracket and dedents a closing one.

## Keys and options

- `(define-mode-language! 'mode "lang")`, `(define-grammar! "name" "git-url" "rev" [subdir])`, commands `install-grammars` and `install-grammar`, `(define-language-alias! "alias" "language")`, `(define-syntax-objects! "lang" function-kinds class-kinds list-kinds)`; primitives `syntax-ancestors`, `syntax-children`, `syntax-tree`, `syntax-at` (the innermost language at an offset, embedded ones included, and its nodes there) and `syntax-children-at` (children in that same tree); these two parse first if the tree is behind the text.
- `smartindent`, `indent-open`, `indent-close`.

## Out of scope

- Folding from the syntax tree ([[folding]]), and tree-sitter indent queries.
- Building or updating grammars without being asked, a list of known grammars to pick from, and grammars whose repository doesn't include a generated `src/parser.c` (they would need the tree-sitter CLI).
- Removing an installed grammar from within imp (delete its files under `grammars/`).
- Locals, textobject and other queries besides highlights and injections.
- Text objects and `smartindent` inside an embedded language: they follow the buffer's own grammar.
- Highlighting Org src blocks by their language; Org isn't parsed with tree-sitter.
