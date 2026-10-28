---
type: Effort
status: active
specs: ["[[spec/tree-sitter]]"]
issue: https://github.com/apisandipas/imp/issues/81
frozen:
  docs/specs/tree-sitter.md: b388bc7bc1c2
---
# Embedded languages

## Approach

All in `crates/imp-server/src/syntax.rs`, as tree-sitter-highlight does it but kept incremental. Each `Lang` gets the injections query its crate exports: HTML's, Markdown's block and inline ones, and Rust's, JavaScript's, Nix's and Lua's, which come with it. Markdown's inline grammar is a language of its own, `markdown_inline`, that no mode names. A `Syntax` keeps its root tree plus a list of layers, one for each injected language region (a set of byte ranges, combined into one when the query says `injection.combined`), each with its own tree. After the root is parsed, the injections query runs over it, and each layer is parsed with `set_included_ranges`. A layer's tree is edited with the root's on every change and reused when the same language comes back at the same place, so typing in a `<script>` reparses it incrementally. Layers nest: a layer's own injections query runs over its tree, up to a depth of 4, so a pathological file can't recurse forever. The root and all layers share the 8 ms budget. Past it, the whole job (root and layers) goes to the background thread, which posts back every tree at once.

`highlights()` runs each layer's highlight query over the visible bytes it covers, and puts deeper layers' captures before outer ones in paint order, so the embedded language draws over the outer. Within a layer the narrower-wins and later-pattern rule stays. Text objects, folds and `smartindent` keep using the root tree only. A language name from `injection.language` is lowercased, then matched against grammar names, then aliases. Aliases live in a table in Rust, filled with the bundled ones and extended by a new `define-language-alias!` primitive. A name nothing matches gives no layer and no message.

Injection queries from imp's config directory and `; inherits:` are left to the runtime-grammars effort. They load from the same place as highlight queries, and that effort writes that loading for both.

Each task has tests in `crates/imp-server/tests/syntax.rs` using `face_on`, and updates `docs/reference/ref-tree-sitter.md` in the same commit.

## Tasks

- [x] Layers, with HTML: `<script>` is highlighted as JavaScript and `<style>` as CSS, over HTML's highlighting. Editing inside the script keeps it highlighted, with the layer reparsed from its old tree. A slow parse still moves to the background, with the layers posted back along with the root (a unit test). With tests.
- [x] Markdown fences and aliases: a fenced block is highlighted in the language its info string names, matched case-insensitively by grammar name, then alias. The bundled aliases (`js`, `ts`, `sh`, `shell`, `zsh`, `py`, `rb`, `ex`, `exs`, `c++`, `yml`, `md`, `htm`, `scm` and the like) are in place, and `(define-language-alias! "alias" "language")` adds one. An unknown name, or an alias whose language isn't bundled (`rb`), leaves the block as Markdown draws it, with no message. YAML and TOML front matter are highlighted too. With tests.
- [x] Markdown inline: `markdown_inline`, tree-sitter-md's inline grammar, is bundled and embedded in every inline region, so emphasis, strong, code spans and links have their faces. Each new capture has a face in the default and Modus themes, which the existing theme test checks. With tests.
- [ ] Nesting and the other bundled injections: a Markdown fence of HTML has its `<script>` drawn as JavaScript. The depth stops at 4. Rust macro bodies are highlighted as Rust, a Nix `buildPhase` string as Bash, and a JavaScript tagged template as its tag's language, with a test for each. The existing languages' tests still pass.
