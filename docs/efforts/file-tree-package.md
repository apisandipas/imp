---
type: Effort
status: active
specs: ["[[spec/file-tree]]"]
issue: https://github.com/apisandipas/imp/issues/55
frozen:
  docs/specs/file-tree.md: f6711257a42f
---
# File tree package

## Approach

A bundled package, `packages/file-tree/file-tree.scm`, written in Scheme on the primitives imp already has: `directory-entries`, `make-directory!`, `rename-file!`, `delete-path!`, `set-buffer-path!` and `confirm!`. The only new Rust is one primitive that says which of a directory's names git ignores, using the `ignore` crate that project file finding already uses (`files.rs`).

The tree is the `*file-tree*` buffer, redrawn from a model kept in Scheme: the root, the set of expanded directories, and the hidden and ignored toggles. Each line's path is kept by line number, so the keys act on the entry under the cursor. The window is made with `split-frame! "left"` and then `resize-window!` to `file-tree-width` columns. It isn't a popup rule, because a popup shares its side with other popups and is closed by `q` through popup handling, while the tree needs one window per frame that survives other popups. Each task ends with tests in `crates/imp-server/tests/file_tree.rs`, and updates `docs/reference/ref-file-tree.md` in the same commit.

## Tasks

- [x] Add a `directory-ignored` primitive that gives the names in a directory git ignores (a list, empty outside a repository), using the `ignore` crate, with a Rust test.
- [x] Add the package: `SPC t e` and `:FileTree` toggle a read-only `*file-tree*` buffer in `file-tree-mode`, down the left at `file-tree-width` columns, at most one per frame. The cursor moves into it, and goes back to the window it came from when it closes, `q` included. It shows the project root's name, then the root's entries, directories first and ending in `/`, each group alphabetical. Dotfiles and ignored files are hidden. Write the reference page's first sections (started with the spec, saying nothing works yet), and add the row in `ref-packages.md` and the README line.
- [x] Expand and collapse: `<ret>` and `<tab>` on a directory open or shut it in place, with entries indented two columns a level. `<ret>` on a file opens it in the window the tree came from, and the cursor goes there. Expanded directories are remembered across closing and reopening, and opening reveals the current buffer's file. All with tests.
- [x] `H` and `I` toggle dotfiles and ignored files, starting from `file-tree-show-hidden` and `file-tree-show-ignored`. `R` reads the directories again, as opening does. All with tests.
- [x] `a` adds a file, or a directory when the name ends in `/`, with its parents, and puts the cursor on it. `r` renames or moves the entry, and a buffer visiting it follows. `D` deletes after `confirm!`, a directory recursively. All with tests.
- [x] `?` shows the tree's keys in a which-key popup, and a second `?` hides it, with a test.
- [ ] With `file-tree-open-at-start` set, the tree opens at startup beside the first window, with the cursor left in that window, with a test.
