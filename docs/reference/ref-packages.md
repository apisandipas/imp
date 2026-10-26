---
type: Page
spec: "[[spec/packages]]"
frozen:
  docs/specs/packages.md: 13552394352f
---
# Packages

Packages add features to imp. Some come with imp but stay off until you ask for them; others you fetch from git or keep in a folder of your own. You declare them all in `init.scm` with `use-package!`.

## Turning on a package that comes with imp

Name it in `init.scm`:

```scheme
(use-package! 'olivetti)
```

These come with imp:

| Package | What it does |
|---|---|
| `olivetti` | Keeps text in a comfortable column in the middle of the window, wrapping between words. `SPC t o` turns it on or off |
| `posframe` | Draws `M-x`, find-file, switch-buffer and other pickers in a box in the middle of the screen |
| `move-lines` | In visual line mode (`V`), `J` and `K` move the selected lines down and up |
| `org-babel` | In Org, `C-c C-c` in a source block runs it and puts the output under the block |
| `nerd-icons` | Nerd Font icons in the status line, the pickers, completion, the file browser and the file tree |
| `file-tree` | The project's folders as a tree down the left. `SPC t e` opens or closes it. See [File tree](ref-file-tree.md) |
| `git-blame` | Shows the last commit to touch the cursor's line, after the line. See [Git blame](ref-git-blame.md) |
| `git-gutter` | A coloured bar beside each line that differs from git. See [Git gutter](ref-git-gutter.md) |
| `org-export` | Exports Org files to HTML, PDF and other formats through pandoc. See [Org export](ref-org-export.md) |

`:packages` lists the packages you've declared, and the ones that come with imp that you haven't.

## Packages from git

Give a package a `'git` address, and imp clones it the first time. `'rev` pins it to a commit, tag or branch.

```scheme
(use-package! 'surround
  'git "https://github.com/someone/imp-surround"
  'rev "4f1c2e9")
```

The clone runs in the background, so the editor starts without waiting. The status line says `cloning surround...`, then `installed surround` once it has loaded. If the clone fails, the status line and `:packages` say why, and the next start tries again.

`:package-update NAME` fetches the package again and reloads it. The editor waits for git while it does.

## Setting a package up

`'config` takes a procedure to run once the package has loaded:

```scheme
(use-package! 'olivetti
  'config (lambda ()
            (set-option! 'olivetti-body-width 72)))
```

Put code that uses a package's functions in its `'config`. A git package may still be cloning when the rest of `init.scm` runs, and `'config` waits for it.

## Your own packages

A package is a folder in `~/.config/imp/packages/`, named after the package. imp loads it from there when you declare it with `use-package!`.

A folder there, or a `'git` package, takes the place of a package of the same name that comes with imp. Packages run like your own `init.scm`, so you can redefine anything they define.

## Options

| Option | Default | What it does |
|---|---|---|
| `packages-dir` | `""` | Where packages live; empty means `~/.config/imp/packages` |
