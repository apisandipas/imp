# Packages

A package is a Scheme file that adds to imp. Some come with imp but stay off until you ask for them. You can also load packages from a git repository, or write your own.

## The packages that come with imp

Turn one on with `use-package!` in your `init.scm`:

```scheme
(use-package! 'git-gutter)
```

| Package | What it does |
|---|---|
| `olivetti` | A centred column of text, for writing |
| `posframe` | `M-x`, find-file and other menus in a box in the middle of the screen |
| `move-lines` | `J` and `K` move the lines selected with `V` |
| `org-babel` | `C-c C-c` runs the code in Org source blocks |
| `nerd-icons` | Icons in the status line and menus (needs a Nerd Font) |
| `git-blame` | The current line's last commit, shown after the line |
| `git-gutter` | A coloured bar beside each changed line; see [Git gutter](ref-git-gutter.md) |
| `org-export` | Export Org files to HTML, PDF and more; see [Org export](ref-org-export.md) |

`:packages` lists what's loaded and what else comes with imp.

## Settings that need the package

A package's own options and functions don't exist until it has loaded. Put the code that uses them in its `'config`, which runs once the package is in:

```scheme
(use-package! 'olivetti
  'config (lambda ()
            (set-option! 'olivetti-body-width 80)
            (set-option! 'olivetti-modes '(org-mode markdown-mode))))
```

## Packages from git

Give a git address to load a package from a repository. `'rev` pins it to a commit, tag or branch:

```scheme
(use-package! 'surround
  'git "https://github.com/someone/imp-surround"
  'rev "4f1c2e9")
```

The first time, imp clones it in the background, so startup doesn't wait. The status line says `cloning surround...`, then `installed surround` once it's loaded. If the clone fails, the status line and `:packages` say why, and imp tries again next time.

`:package-update NAME` fetches the package again and reloads it.

## Writing your own

A package is a directory in `~/.config/imp/packages/`. Its main file is `NAME.scm`, `init.scm` or `package.scm`:

```
~/.config/imp/packages/
  hello/
    hello.scm
```

It's ordinary Scheme, like `init.scm`, and can define commands, keys, options and hooks:

```scheme
;;; hello.scm -- says hello.

(define-command! 'hello
  (lambda (count)
    "Say hello on the message line."
    (message "hello")))
```

Load it with `(use-package! 'hello)`. A package in this directory takes the place of a bundled one with the same name, so you can copy one of imp's packages and change it.

To share a package, put its directory in a git repository and have others load it with `'git`.

## Next

[Coming from Emacs or Vim](coming-from.md).
