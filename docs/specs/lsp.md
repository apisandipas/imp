---
status: accepted
summary: "Language servers: diagnostics, navigation, rename, code actions, formatting and completion."
anchors: [runtime/lsp.scm, crates/imp-server/src/lsp.rs, crates/imp-server/src/json.rs, crates/imp-server/tests/lsp.rs]
---
# LSP

Framing and JSON are Rust; the protocol and the features are Scheme. Servers run as jobs, so a slow one never blocks typing.

## Behaviour

- Servers per major mode, one per (command, root), found by root markers. Positions are negotiated as UTF-32 (imp's offsets are chars), with UTF-16 as the fallback.
- Documents: didOpen, didChange (full text, debounced), didSave, didClose. Replies to the usual server requests, including `workspace/applyEdit`.
- **Diagnostics**: underlined, a gutter sign, the message on the status line in normal mode, `]d [d :diagnostics`. Pushed and pulled (`textDocument/diagnostic`, `workspace/diagnostic/refresh`). Held while you type, until insert ends, like Neovim's `update_in_insert = false`. They move with the text as you edit, until the server sends new ones.
- **Navigation and edits**: `K` hover, `gd` definition, `gr` references (through the menu), `SPC c r` rename across files, `SPC c a` code actions (with commands and resolve), `SPC c f` format, `SPC c x` diagnostics, `SPC c R` restart.
- **Completion** in insert mode ([[completion-at-point]]): `C-x C-o`, `C-n`/`C-p`, and as you type after word or trigger characters, in a bordered box at the cursor. Replies stay in Rust (TypeScript sends about 16k items); a new request cancels the previous one. Sorted by `sortText`, `additionalTextEdits` applied, incomplete lists re-requested, snippets expanded.
- Defaults, used when installed: rust-analyzer, typescript-language-server (tsgo first, then typescript-language-server, then `tsc --lsp`), nil, marksman, pyright.
- `:lsp-info :lsp-log :lsp-restart :lsp-stop`.

## Keys and options

- `lsp` (turns them all off), `lsp-auto-complete`, `lsp-change-delay`, `lsp-diagnostics-in-insert`.
- `(define-language-server! 'mode "command args" '("root-marker" ...) "languageId")`, or a list of commands to use the first installed.

## Out of scope

- Signature help and inlay hints.
- File create, rename and delete in workspace edits (refused).

## Known gaps

- Document sync sends the full text, because `after-change` doesn't report the changed range. [#6](https://github.com/apisandipas/imp/issues/6)
- Dot-repeat of a completion replays it as backspaces plus the typed word.
