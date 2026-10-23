---
status: accepted
summary: "use-package!: loading local, git and bundled packages."
anchors: [runtime/packages.scm, crates/imp-server/tests/packages.rs]
---
# Packages

How packages load; the packages shipped with imp are listed in `packages/CONTEXT.md` ([[0011-non-essential-features-are-opt-in-packages]]).

## Behaviour

- `(use-package! 'name 'git URL 'rev REV 'config thunk)` in `init.scm` declares a package. A package in `packages-dir` (`~/.config/imp/packages/NAME/`), or a `'git` one, is loaded from there; otherwise a bundled package of that name.
- A `'git` package is cloned when missing and pinned to `'rev` when given. `'config` runs after it loads.
- Packages are evaluated like user code, so their definitions are redefinable and a config may name functions defined later.
- `:packages` lists them.

## Keys and options

`packages-dir`.

## Known gaps

- Cloning a `'git` package blocks the editor at startup. [#13](https://github.com/apisandipas/imp/issues/13)
