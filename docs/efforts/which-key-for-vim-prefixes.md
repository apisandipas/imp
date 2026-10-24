---
type: Effort
status: active
specs: ["[[spec/leader-and-modes]]"]
issue: https://github.com/apisandipas/imp/issues/9
frozen:
  docs/specs/leader-and-modes.md: a68b5eddbf8a
---
# Which-key for Vim prefixes

Show the which-key popup after Vim's prefix keys (`g`, `z`, `Z`, `[`, `]`, `C-w`), with a label for each key.

## Approach

Vim's keys after a prefix live in several tables: keymaps (`define-key!`, mode keys included), `*motions*`, `*operators*` and `*char-commands*`. None carries a description, so labels go in a separate hash keyed by where the key was bound, filled by an optional last argument (a rest argument, as `completing-read` does) on `define-key!`, `define-motion!`, `define-operator!` and `define-mode-key!`. A key's continuations after a prefix are collected from the same tables `normal-key!` looks in, in the same order, so the popup lists exactly what would run and a mode key's label wins. The popup reuses `which-key-table` and `show-which-key-popup!` from `leader.scm`, and its timer follows `show-which-key!`: it shows only if the same prefix is still pending when `which-key-delay` ends. `leader.scm` loads after `vim.scm`, so `normal-key!` calls the popup through a hook variable that `leader.scm` sets, as `*command-labels*` is set today.

## Tasks

- [x] Labels: `define-key!`, `define-motion!`, `define-operator!` and `define-mode-key!` take an optional label, and `(binding-label state key)` returns the label, else the bound command's name, else #f, looking in mode keymaps first. Tested in `leader.rs`.
- [x] Continuations: `(prefix-continuations state prefix)` lists the bound keys after `prefix` in normal or visual state, from mode keymaps, the state's keymap, operators, motions and (in visual) text objects, each once with its description, sorted. Tested with a mode key overriding a Vim key's label.
- [ ] Popup: typing a prefix from `*prefix-keys*` (or `define-prefix!`) in normal or visual state shows the which-key popup after `which-key-delay`, titled with the count and prefix (`3g`); the next key or <esc> closes it. No popup for `"`, char motions, or while an operator is pending; a key typed before the delay ends means no popup. Tested in `leader.rs` with `which-key-delay` 0 and with a delay.
- [ ] Labels for imp's own keys: every key bound after `g`, `z`, `Z`, `[`, `]` and `C-w` in the runtime and bundled modes (LSP, dired, scheme) has a short label, with a test that fails when one is added without.
- [ ] Docs: the docstrings of the four define functions mention the label, and `docs/specs/vim.md` points to which-key for the prefix keys if it lists them.
