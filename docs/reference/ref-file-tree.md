---
type: Page
spec: "[[spec/file-tree]]"
frozen:
  docs/specs/file-tree.md: ca9762e7a370
---
# File tree

The file tree shows your project's folders as a tree down the left of the screen, as most editors' sidebars do. It sits beside the [file browser](ref-dired.md), which stays the way to edit a directory as text.

## Turning it on

The file tree is an opt-in package. Load it near the top of your `init.scm`:

```scheme
(use-package! 'file-tree)
```

## Opening and closing it

Press `SPC t e`, or type `:FileTree`, to open the tree. It opens down the left, 30 columns wide, and the cursor moves into it. Press `SPC t e` again, from the tree or from any other window, to close it. `q` in the tree closes it too. Either way the cursor goes back to the window you opened it from.

With the [daemon](ref-daemon.md), each client has its own tree, so two clients can each show a different project.

The tree shows the project the current file is in (see [Projects](ref-projects.md)), or the folder you started imp in. The project's name is on the first line. Below it are its folders, ending in `/`, and then its files, each in alphabetical order.

Dotfiles, and files git ignores, aren't shown at first: `H` shows or hides dotfiles, and `I` shows or hides ignored files.

When the tree opens, it opens the folders down to the file you're in and puts the cursor on it. While it's open, it follows you: switch to another file in one of its projects, and the tree opens the folders down to that file and moves its cursor there. Your cursor stays where you are. Set `file-tree-follow` to `#f` to turn this off.

## Moving around

Move with `j` and `k`, search with `/`, and use any other Vim motion, as in any buffer.

- `<ret>` or `<tab>` on a folder opens it in place, its contents indented under it. Press it again to shut it.
- `<ret>` on a file opens it in the window you opened the tree from, and moves the cursor there. The tree stays open.
- Clicking does the same: click a folder to open or shut it, or a file to open it.

The tree reads the folders again each time it opens. If files change while it's open, press `R` to read them again.

The tree remembers which folders you opened. Close it and open it again, and they're still open, until you quit imp.

Press `?` in the tree to see its keys in a popup at the bottom of the screen. Press `?` again to hide it.

## Icons

With the [nerd-icons](ref-packages.md) package loaded, each entry has an icon before its name: the file's type, or a folder, open or shut. Your font needs Nerd Font icons.

## Git status

In a git repository, the tree shows what's changed. A changed file's name is coloured, with a letter after it:

| Letter | Means | Face |
|---|---|---|
| `M` | Changed since the last commit, staged or not | `file-tree.modified` |
| `A` | A new file, added to the index | `file-tree.added` |
| `U` | A new file git doesn't track yet | `file-tree.untracked` |
| `!` | A merge conflict | `file-tree.conflict` |

A folder with changes inside it takes the colour of the most serious one: a conflict, then a change, then a new file. It has no letter. When you show ignored files with `I`, they're dimmed, in `file-tree.ignored`.

The status updates when the tree opens, when you press `R`, after `a`, `r` or `D`, and when you save a file in one of the tree's projects. Git runs in the background, so the tree appears first and the colours follow a moment later. Outside a repository, nothing is coloured.

Change the colours in `init.scm`:

```scheme
(set-face! "file-tree.modified" "fg=#e69875")
```

## More than one project

Press `P` in the tree to add another project beside the first. Pick one of the projects you've opened before, or type the path of any folder. It shows below the first, with its own folders under its name. The tree remembers the projects you add, even after you quit imp.

To take one out, put the cursor on its name and press `X`. The folder itself isn't touched. The first project, the one the tree opened on, always stays.

## Adding, renaming and deleting

- `a` asks for a name to add in the folder at the cursor. On a file, it adds beside the file, and on a project's name, at the top of that project. A name ending in `/` makes a folder. A name with folders in it, such as `lib/mod.rs`, makes the folders too. The cursor then moves to what you added.
- `r` asks for a new path for the entry at the cursor, starting from its current path. Change the name to rename it, or change the folders to move it. A file you have open follows it, so saving writes to the new path.
- `D` deletes the entry at the cursor, once you answer `y`. A folder is deleted with everything in it.

There's no copy and paste of files, and no drag and drop. For changing many names at once, the [file browser](ref-dired.md) lets you edit a folder's listing as text.

## Opening it when imp starts

To have the tree open whenever imp starts, set `file-tree-open-at-start` after loading the package:

```scheme
(use-package! 'file-tree
  'config (lambda () (set-option! 'file-tree-open-at-start #t)))
```

The cursor stays in the file you opened, with the tree beside it.

## Options

| Option | Default | What it does |
|---|---|---|
| `file-tree-width` | `30` | How many columns wide the tree opens |
| `file-tree-show-hidden` | `#f` | Whether dotfiles are shown; `H` flips it |
| `file-tree-show-ignored` | `#f` | Whether files git ignores are shown; `I` flips it |
| `file-tree-open-at-start` | `#f` | Whether the tree opens when imp starts |
| `file-tree-follow` | `#t` | Whether the tree moves to each file you switch to |
