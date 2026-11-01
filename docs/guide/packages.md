---
type: Guide
specs: ["[[spec/packages]]", "[[spec/olivetti]]", "[[spec/posframe]]", "[[spec/move-lines]]", "[[spec/showkeys]]", "[[spec/file-tree]]", "[[spec/git-blame]]", "[[spec/git-gutter]]", "[[spec/modus-themes]]", "[[spec/org-export]]"]
frozen:
  docs/specs/packages.md: e9a16175b04a
  docs/specs/olivetti.md: 5b1ed15a4236
  docs/specs/posframe.md: 9dd5f8aa7b18
  docs/specs/move-lines.md: d4c34470f45d
  docs/specs/showkeys.md: 8d44499288a6
  docs/specs/file-tree.md: 93c6d2be9759
  docs/specs/git-blame.md: d6706377c008
  docs/specs/git-gutter.md: 50690fac14f4
  docs/specs/modus-themes.md: 2f7f2ca55f07
  docs/specs/org-export.md: d011ff8473b5
---
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
| `nerd-icons` | Icons in the status line, menus, the file browser and the file tree (needs a Nerd Font) |
| `file-tree` | The project's folders as a tree down the left, `SPC t e`; see [File tree](ref-file-tree.md) |
| `git-blame` | The current line's last commit, shown after the line |
| `git-gutter` | A coloured bar beside each changed line; see [Git gutter](ref-git-gutter.md) |
| `org-export` | Export Org files to HTML, PDF and more; see [Org export](ref-org-export.md) |
| `modus-themes` | The Modus Vivendi and Modus Operandi themes from Emacs; see [Modus themes](ref-modus-themes.md) |

`M-x list-packages` lists what's loaded and what else comes with imp.

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

The first time, imp clones it in the background, so startup doesn't wait. The status line says `cloning surround...`, then `installed surround` once it's loaded. If the clone fails, the status line and `M-x list-packages` say why, and imp tries again next time.

`M-x package-update` fetches a package again and reloads it.

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

A command runs from `M-x` and from `:` by its name (`:hello`). Make each thing your package does a command like this, not a `:` command of its own. A command that needs an answer asks for it, and `:NAME text` answers it:

```scheme
(define-command! 'greet
  (lambda (count)
    "Greet someone by name."
    (completing-read "Greet: " '("Ada" "Grace")
                     (lambda (name) (message (string-append "hello " name))))))
```

`M-x greet` asks, and `:greet Ada` says hello to Ada straight away.

Load it with `(use-package! 'hello)`. A package in this directory takes the place of a bundled one with the same name, so you can copy one of imp's packages and change it.

To share a package, put its directory in a git repository and have others load it with `'git`.

## Next

[Coming from Emacs or Vim](coming-from.md).
