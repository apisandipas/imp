---
status: accepted
issue: https://github.com/apisandipas/imp/issues/13
summary: "use-package!: loading local, git and bundled packages."
anchors: [runtime/packages.scm, crates/imp-server/tests/packages.rs]
---
# Packages

How packages load; the packages shipped with imp are listed in `packages/CONTEXT.md` ([[0011-non-essential-features-are-opt-in-packages]]).

## Behaviour

- `(use-package! 'name 'git URL 'rev REV 'config thunk)` in `init.scm` declares a package. A package in `packages-dir` (`~/.config/imp/packages/NAME/`), or a `'git` one, is loaded from there; otherwise a bundled package of that name.
- A `'git` package is cloned when missing and pinned to `'rev` when given. `'config` runs after it loads.
- The clone runs in the background, so the editor starts without waiting. The status line says `cloning NAME...`, then `installed NAME` once it has loaded and run its `'config`; a failed clone says why there and in `:packages`, and leaves nothing behind, so the next start tries again. Code in `init.scm` that uses a package's functions belongs in its `'config`, which waits for the package.
- Packages are evaluated like user code, so their definitions are redefinable and a config may name functions defined later.
- `:packages` lists them.

## Keys and options

`packages-dir`.

## Out of scope

- `:package-update` still waits for git.
