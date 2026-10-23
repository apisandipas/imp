---
status: accepted
summary: "The insert-mode completion menu and its sources, and snippets."
anchors: [runtime/complete.scm, runtime/snippet.scm, crates/imp-server/src/complete.rs, crates/imp-server/tests/complete.rs, crates/imp-server/tests/snippet.rs]
---
# Completion at point

Completion while typing, after nvim-cmp, and snippets.

## Behaviour

- Sources come in groups: the first group with candidates wins and its sources merge, ranked by match, then priority. The default groups are `(file (lsp scheme words))`.
- It opens as you type in `completion-auto-modes` (prog-mode) after `completion-auto-min` characters, and on request.
- The hot paths are Rust: a per-buffer word index (nearest the cursor first) and a candidate store that each key filters and ranks, returning the top 200.
- The command line (`:`, `/`, `?`) has its own menu through `*cmdline-completer*` and a second store.
- Snippets use LSP/VS Code syntax: `<tab>` and `<s-tab>` move between stops, a selected placeholder is replaced by typing, choices use the menu. LSP snippet items expand on accept.

## Keys and options

- `C-x C-o`, `C-n`, `C-p` in insert mode.
- `completion-keys` (`vim`, `tab` or `enter`), `completion-menu-columns`, `completion-words-scope`, `completion-auto-modes`, `completion-auto-min`, `cmdline-completion`.
- `(define-completion-source! name (lambda (manual? done) ...) 'priority N 'min-length N 'auto PRED 'exclusive #t)`, `(set-completion-sources! mode groups)`, `define-snippet!`, `load-snippets!`.
