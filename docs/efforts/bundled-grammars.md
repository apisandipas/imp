---
type: Effort
status: done
specs: ["[[spec/tree-sitter]]"]
issue: https://github.com/apisandipas/imp/issues/81
frozen:
  docs/specs/tree-sitter.md: 5ef9165969ad
---
# Bundled grammars

The first of #81's three efforts: the thirteen new bundled grammars. Embedded languages and runtime grammars come after, as efforts of their own.

## Approach

Each grammar is a crates.io crate built on the `tree-sitter-language` crate, so it works with the `tree-sitter` 0.25 imp already uses. Each one is added to the workspace `Cargo.toml` and to the list in `languages()` in `syntax.rs`, with the highlight query its crate exports, as the six bundled grammars are now. The crates are tree-sitter-html, tree-sitter-css, tree-sitter-json, tree-sitter-yaml, tree-sitter-toml-ng, tree-sitter-bash, tree-sitter-c, tree-sitter-cpp, tree-sitter-go, tree-sitter-python, tree-sitter-lua, tree-sitter-elixir and tree-sitter-ruby. tree-sitter-cpp, tree-sitter-elixir and tree-sitter-ruby were later dropped: they added 6.7 MB of the 10.1, and their users can install them. The modes already in `runtime/modes.scm` get their language in `*mode-languages*` in `syntax.scm`; `elixir-mode` and `ruby-mode` are new modes beside them. A capture whose face falls back to nothing the theme sets gets a fallback face in `theme.scm`, and in the Modus themes. The Nix build reads `Cargo.lock`, so it needs no hash change.

Each task's test opens a sample file in each of its languages and checks that a keyword, string or tag is drawn in its `syntax.` face, in `crates/imp-server/tests/syntax.rs`, and each task updates `docs/reference/ref-tree-sitter.md`'s list of languages in the same commit. The binary's size before and after goes in the PR.

## Tasks

- [x] HTML, CSS and JSON: `html-mode` (`.html`, `.htm`, `.xml`, `.svg`), `css-mode` (`.css`, `.scss`) and `json-mode` parse with them and highlight, with tests.
- [x] Where captures overlap, the narrower one wins; of captures of the same text, the later pattern wins, as in tree-sitter's own highlighter (corrected from the earlier pattern, which needed exceptions for Rust's doc comments and YAML's keys). Test with a nested capture, and check the existing languages' tests still pass.
- [x] YAML, TOML and Bash: `yaml-mode`, `toml-mode` and `shell-mode` parse with them and highlight, with tests. YAML's keys are `property`.
- [x] C, Go and Python (C++ was later left out, see the last task): their modes parse with them and highlight, and `af`, `ac` and `aa` work with each grammar's function, class or type, and argument-list node kinds, with tests.
- [x] Lua, Elixir and Ruby (Elixir and Ruby later left out, see the last task): new `elixir-mode` (`.ex`, `.exs`) and `ruby-mode` (`.rb`, `.rake`, `Rakefile`, `Gemfile`), with their comment strings and indentation like the other modes. All three parse and highlight, with text objects as above, and tests.
- [x] Every capture the new queries use is drawn in a face the default theme and the Modus themes set, through fallback if not by name. A test checks the captures of each new query against the theme.
- [x] Leave C++, Elixir and Ruby out of the binary at the owner's request: drop their crates, keep `cpp-mode`, `elixir-mode`, `ruby-mode`, their language names and text objects for a grammar installed later, and test that those files get their mode with no parse.
