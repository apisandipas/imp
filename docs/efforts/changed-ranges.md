---
type: Effort
status: active
specs: ["[[spec/live-scheme-and-help]]", "[[spec/lsp]]"]
issue: https://github.com/apisandipas/imp/issues/6
frozen:
  docs/specs/live-scheme-and-help.md: 2bdca45a37b7
  docs/specs/lsp.md: 681e20cfd499
---
# Changed ranges

Report what an edit changed, and use it for incremental LSP sync.

## Approach

`Buffer` keeps a log of its last 1000 edits in chars, each tagged with the version it produced: start, old end, new end, the inserted text, and the line and column of start and old end before the edit. An undo, redo or reload clears it and marks the versions before as unknown. Scheme reads it with `buffer-changes-since`, so any number of readers (LSP, completion, packages) can each keep their own version instead of one taking the edits from the others, as the tree-sitter tracker does. `after-change-range` folds the key's edits into one range, using the version `vim.scm` already keeps for running `after-change`. LSP sends the edits since the version it last sent when the server asked for incremental sync and counts UTF-32 (imp's columns are chars, and after the edit the old text isn't there to count UTF-16 in); otherwise the full text.

Decisions made while the owner was away (issue #6 had no answers yet): the hook keeps taking no arguments and the range is a function, so no existing hook breaks; incremental sync only for UTF-32 servers; a log of 1000 edits.

## Tasks

- [x] `Buffer` logs edits with their versions, cleared by undo, redo and reload, capped at 1000; `changes_since(version)`. Unit tests in `buffer.rs`.
- [ ] Scheme: `buffer-changes-since` and `after-change-range`. Tested in `hooks.rs`, including several edits in one key and an undo.
- [ ] LSP sends incremental changes to servers that ask for them and count UTF-32, the full text otherwise. The fake server applies ranges (and has a full-sync mode); `lsp.rs` tests both.
- [ ] Docs: `runtime/CONTEXT.md` extension points mention the change log.
