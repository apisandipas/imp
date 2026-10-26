---
type: Page
spec: "[[spec/file-tree]]"
frozen:
  docs/specs/file-tree.md: f6711257a42f
---
# File tree

The file tree shows your project's folders as a tree down the left of the screen, as most editors' sidebars do. It sits beside the [file browser](ref-dired.md), which stays the way to edit a directory as text.

## Not yet in imp

- The file tree is being built ([issue #55](https://github.com/apisandipas/imp/issues/55)). It can't open by itself when imp starts yet.

## Turning it on

The file tree is an opt-in package. Load it near the top of your `init.scm`:

```scheme
(use-package! 'file-tree)
```

## Opening and closing it

Press `SPC t e`, or type `:FileTree`, to open the tree. It opens down the left, 30 columns wide, and the cursor moves into it. Press `SPC t e` again, from the tree or from any other window, to close it. `q` in the tree closes it too. Either way the cursor goes back to the window you opened it from.

The tree shows the project the current file is in (see [Projects](ref-projects.md)), or the folder you started imp in. The project's name is on the first line. Below it are its folders, ending in `/`, and then its files, each in alphabetical order.

Dotfiles, and files git ignores, aren't shown at first: `H` shows or hides dotfiles, and `I` shows or hides ignored files.

When the tree opens, it opens the folders down to the file you're in and puts the cursor on it.

## Moving around

Move with `j` and `k`, search with `/`, and use any other Vim motion, as in any buffer.

- `<ret>` or `<tab>` on a folder opens it in place, its contents indented under it. Press it again to shut it.
- `<ret>` on a file opens it in the window you opened the tree from, and moves the cursor there. The tree stays open.

The tree reads the folders again each time it opens. If files change while it's open, press `R` to read them again.

The tree remembers which folders you opened. Close it and open it again, and they're still open, until you quit imp.

Press `?` in the tree to see its keys in a popup at the bottom of the screen. Press `?` again to hide it.

## Adding, renaming and deleting

- `a` asks for a name to add in the folder at the cursor. On a file, it adds beside the file, and on the first line, at the top of the project. A name ending in `/` makes a folder. A name with folders in it, such as `lib/mod.rs`, makes the folders too. The cursor then moves to what you added.
- `r` asks for a new path for the entry at the cursor, starting from its current path. Change the name to rename it, or change the folders to move it. A file you have open follows it, so saving writes to the new path.
- `D` deletes the entry at the cursor, once you answer `y`. A folder is deleted with everything in it.

There's no copy and paste of files, and no drag and drop. For changing many names at once, the [file browser](ref-dired.md) lets you edit a folder's listing as text.

## Options

| Option | Default | What it does |
|---|---|---|
| `file-tree-width` | `30` | How many columns wide the tree opens |
| `file-tree-show-hidden` | `#f` | Whether dotfiles are shown; `H` flips it |
| `file-tree-show-ignored` | `#f` | Whether files git ignores are shown; `I` flips it |
