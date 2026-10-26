---
type: Page
spec: "[[spec/file-tree]]"
frozen:
  docs/specs/file-tree.md: f6711257a42f
---
# File tree

The file tree shows your project's folders as a tree down the left of the screen, as most editors' sidebars do. It sits beside the [file browser](ref-dired.md), which stays the way to edit a directory as text.

## Not yet in imp

- The file tree is being built ([issue #55](https://github.com/apisandipas/imp/issues/55)). Folders don't open yet, and you can't add, rename or delete files from it.

## Turning it on

The file tree is an opt-in package. Load it near the top of your `init.scm`:

```scheme
(use-package! 'file-tree)
```

## Opening and closing it

Press `SPC t e`, or type `:FileTree`, to open the tree. It opens down the left, 30 columns wide, and the cursor moves into it. Press `SPC t e` again, from the tree or from any other window, to close it. `q` in the tree closes it too. Either way the cursor goes back to the window you opened it from.

The tree shows the project the current file is in (see [Projects](ref-projects.md)), or the folder you started imp in. The project's name is on the first line. Below it are its folders, ending in `/`, and then its files, each in alphabetical order.

Dotfiles, and files git ignores, aren't shown.

## Options

| Option | Default | What it does |
|---|---|---|
| `file-tree-width` | `30` | How many columns wide the tree opens |
