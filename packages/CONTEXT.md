# packages

Opt-in packages that ship with imp ([[0011-non-essential-features-are-opt-in-packages]]). Each is `packages/NAME/NAME.scm`, embedded through `PACKAGES` in `crates/imp-server/src/lib.rs` (read from beside `IMP_RUNTIME` in development), and loads only with `(use-package! 'NAME)`. A package in the user's packages directory, or a `'git` package of the same name, wins over the one shipped.

- `olivetti`: a centred column of text that wraps between words.
- `posframe`: completion menus in a centred box with the prompt inside.
- `org-babel`: `C-c C-c` runs an Org source block, results under `#+RESULTS:`.
- `move-lines`: `J` and `K` move a visual line selection.
- `nerd-icons`: Nerd Font icons in completion, menus and the status line.
- `git-blame`: the cursor's line's last commit, after the line.

The rules of `runtime/` apply here too: docstrings on every function, and core gets only the primitive a package can't do without.
