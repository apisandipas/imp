---
type: Effort
status: done
specs: ["[[spec/file-tree]]"]
issue: https://github.com/apisandipas/imp/issues/78
frozen:
  docs/specs/file-tree.md: ca9762e7a370
---
# File tree follow-ups

## Approach

All in `packages/file-tree/file-tree.scm`, on primitives imp already has; no new Rust. Each open tree gets its own buffer, recorded with its window in `*file-tree-origins*`, so daemon clients stop sharing one; the tree's window is found from that record rather than from a buffer name. Rows carry the root they belong to, so `r` and the prompts work relative to it, and extra roots are a list saved in imp's state directory beside the remembered projects.

Git status comes from `git status --porcelain` in each root's repository, run with `start-job!` as git-blame runs `git blame`, and kept per root until the next refresh. A name's face is a `buffer-highlight-add!` range and its letter is end-of-line text (`set-line-end-text!`). Icons are part of the line text, between the indent and the name, from the runtime's `*dired-icon*` hook, which the nerd-icons package already sets, and a new `*open-folder-icon*` beside it. The hooks live in the runtime rather than in either package, so the two packages can load in either order. They aren't drawn as display-only text because the margin pads every line to the widest, which would undo the indent, and a per-line prefix would be a new core feature. The tree is read-only, so text icons cost nothing. Following the current buffer uses the `buffer-enter` hook and redraws only when the file isn't already shown.

Each task ends with tests in `crates/imp-server/tests/file_tree.rs` and updates `docs/reference/ref-file-tree.md` in the same commit.

## Tasks

- [x] Give each tree its own buffer (`*file-tree*`, then `*file-tree 2*` while another client has one open), killed when the tree closes. Find the tree window from `*file-tree-origins*`, and never drop another client's entries. Test with two daemon clients, each with a tree on a different project, and remove the known gap from the reference page.
- [x] Rows carry their root. `P` adds a root, picked with completion from the remembered projects or typed as a directory. `X` removes an added root. Added roots come after the first, are shown once, and are saved in the state directory, so a new server shows them. All with tests.
- [x] `file-tree-follow` (on): switching to a buffer whose file is under a root expands the tree down to it and moves the tree window's cursor there, without moving focus. A file under no root changes nothing, and with the option off nothing follows. All with tests.
- [x] Git status: a background `git status` per root's repository gives `M`, `A`, `U` and `!` as end-of-line letters, with the name in `file-tree.modified`, `file-tree.added`, `file-tree.untracked` or `file-tree.conflict`. A folder takes the face of its most serious change, with no letter, and shown ignored files are in `file-tree.ignored`. It refreshes on open, on `R`, after `a`, `r` and `D`, and after a file under a root is saved. Add the faces to `theme.scm` and the Modus themes. Test against a real repository.
- [x] Icons: the runtime's `*dired-icon*` gives a file's or shut folder's icon, and a new `*open-folder-icon*` beside it in `dired.scm` an open folder's, drawn between the indent and the name, with the cursor on the name. nerd-icons sets both. Test with stub icons and with nerd-icons loaded.
- [x] Clicks: a `mouse-click` hook in `runtime/mouse.scm`, run after a left click lands in a window's text, and the tree acts on it as `<ret>` does: a folder opens or shuts, a file opens in the tree's origin window. A click on a root's line or below the last entry does nothing more. Tests in `mouse.rs` and `file_tree.rs`.
