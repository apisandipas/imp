---
status: accepted
summary: "The minibuffer menu: completing-read, M-x, find-file, switch-buffer, describe-*."
anchors: [runtime/completion.scm, crates/imp-server/src/fuzzy.rs, crates/imp-server/tests/completion.rs]
---
# Completion

A vertico/orderless-style menu at the prompt, one of the packages a new editor needs to attract users.

## Behaviour

- `(completing-read prompt candidates on-select)` opens a prompt with a menu of matches that narrows as you type.
- Matching is orderless: the query splits on spaces and every part must match, as a substring or else a fuzzy subsequence, ranked by score. Filtering is in Rust (`fuzzy-filter`), since a project's file list can be large.
- `C-n C-p <up> <down>` move, `<ret>` takes the selection (or the typed text when nothing matches), `<esc>` cancels.
- Used by M-x, find-file, switch-buffer (offering the alternate buffer first) and describe-*.
- M-x shows each command's keys (normal mode's and the leader's) and the first line of its docstring, else its `document-command!` text, else its which-key label.
- Choosing a file, `<tab>` completes the typed path a part at a time, as Emacs does, and moves down the menu when there's nothing to add. find-file lists the project's files, skipping what `.gitignore` does (inside a git repository); a path starting with `/`, `~/`, `./` or `../` lists that directory instead, fuzzy on its last part, without hidden files.

## Keys and options

- `M-x`, `SPC :` and `SPC SPC` run commands; `SPC f f` finds a file, `SPC b b` switches buffer.
- `*completion-category*` tells packages (icons) what is being chosen.

## Known gaps

- Long paths in menus are cut at the screen edge rather than shortened from the start.
