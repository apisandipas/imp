---
type: Effort
status: done
specs: ["[[spec/vim]]"]
issue: https://github.com/apisandipas/imp/issues/8
frozen:
  docs/specs/vim.md: 1d9958d59cf3
---
# Map commands

Vim's `:map` family, built on imp's keymaps.

## Approach

A new `runtime/map.scm`, loaded after `modes.scm`, because it needs `define-leader!` and wraps the `*local-keymaps*` that `modes.scm` sets. Mappings live in their own keymaps (`map:normal`, `map:visual`, `map:insert`), appended after the buffer's mode keymaps, so they win over Vim's built-ins as mode keys already do (`normal-key!` looks in mode keymaps before operators and motions) and leave buffer-local keys first. A mapping's binding plays its `{rhs}` keys with `play-keys!`; for `noremap` a flag hides the map keymaps while they play, and a depth counter stops runaway recursion. Vim notation is converted to imp's key names by a small parser. Insert-state mappings of several keys use a pending state with `timeoutlen`, inserting the first keys as typed and removing them when the mapping completes, as Vim shows it.

Decisions made while the owner was away (issue #8 had no answers yet): `:map` covers normal and visual only (no operator-pending); a multi-key normal `{lhs}` must start with a prefix, `<Leader>` or an unbound key, with no timeout for keys that already do something; `<silent>` is accepted and ignored, other `<...>` arguments are errors; `timeoutlen` defaults to Vim's 1000 ms.

## Tasks

- [x] Vim key notation: `(vim-keys text)` turns `<CR>`, `<C-x>`, `<Leader>`, `<lt>` and the rest, case-insensitive, into imp key names. Tested in a new `map.rs`.
- [x] `:nmap`, `:vmap`, `:map` and the `noremap` forms for normal and visual: mappings after mode keys, counts passed on, `noremap` not seeing mappings, recursion stopped at 100, `<Leader>` into the leader tree, multi-key `{lhs}` rules with an error otherwise, the `{rhs}` as which-key label. Tested.
- [x] `:imap` and `:inoremap`, single keys and several keys with `timeoutlen`. Tested, including the timeout passing.
- [x] `:unmap`, `:nunmap`, `:vunmap`, `:iunmap`, and listing with no arguments or only an `{lhs}`. Tested.
- [x] Docs: `runtime/CONTEXT.md` load order and extension points, and a README line on `:map` (and `run-ex!` in `init.scm`).
