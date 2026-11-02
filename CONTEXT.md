# imp

An editor as flexible as Emacs, designed in 2026, and Vim-first. What imp takes from Emacs is not Lisp but this: almost all of the editor is written in its own extension language and can be redefined while it runs. The test, stated early and worth keeping: if most of the editor isn't written in the extension language, we have built VS Code, not Emacs. Every key's meaning is in Scheme ([[0005-rust-owns-data-and-speed-scheme-owns-behavior]]).

Repo: https://github.com/apisandipas/imp. Owner: Bryan Paronto (@apisandipas). Website: https://apisandipas.github.io/imp/ (`site/`).

## Layout

- `crates/imp-core`: shared types and the client/server protocol.
- `crates/imp-server`: the editor: state, the event loop, rendering, and the Rust/Scheme boundary (`src/api/`).
- `crates/imp`: the `imp` binary (package `imp-editor`) and the terminal client.
- `crates/imp-gui`: the window client.
- `runtime/`: the editor itself, in Steel Scheme, loaded at startup.
- `packages/`: opt-in packages that ship with imp.
- `docs/`: lore notes: `decisions/`, `specs/`, `efforts/`. `.lore/WORKFLOW.md` is the process. The user docs the website builds (`tools/site-docs.py`): `guide/`, written by hand, and `reference/`, a page per spec. `docs/steel.md`: Steel Scheme's gotchas.
- `tools/`: checks and scripts for driving the real binary.
- `examples/`: a starter `init.scm`, a `config.kdl`, a WASM plugin.

## Working on it

```sh
nix develop            # sets IMP_RUNTIME=$PWD/runtime, so Scheme edits need only a restart
cargo run -- FILE
tools/check.sh         # tests, clippy, fmt: run before pushing a branch
```

Without Nix: install Rust (rustup) and a C compiler, export `IMP_RUNTIME=$PWD/runtime` yourself, and install `rg` for project search. `make` lists every build, install and test target; it uses plain cargo, and runs it inside `nix develop` when Nix is installed. Installs must work for people without Nix: keep the README leading with the binaries and `make install`.

## Rules

- New editing behavior goes in Scheme. Add a primitive to `crates/imp-server/src/api/` only when Scheme can't do it or measures too slow (`cargo run --release -p imp-server --example bench`); keep primitives small and general.
- Match real Vim. Test Vim behavior by feeding keys and asserting text and cursor, compared against Vim or Neovim: Vim users leave the moment their habits break.
- Every function and command in `runtime/` and `packages/` has an Emacs-style docstring; variables and options get a comment above.
- What isn't essential to editing is an opt-in package ([[0011-non-essential-features-are-opt-in-packages]]).
- Comments explain why, as in the existing code. Match the surrounding style.

## Branches and issues

- Ideas and bugs are GitHub Issues (forms in `.github/ISSUE_TEMPLATE`).
- `develop` is where work lands. Each piece of work gets a `type/slug` branch from it: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, or `site`. When `tools/check.sh` and `lore check` pass, merge it into `develop` with `git merge --no-ff`.
- `main` changes only for a release (merge `develop` into it) or a website update. A `site/` branch starts from `main` and merges back into `main`, so no unreleased code comes along; then merge `main` into `develop`.
- Nothing is committed straight to `main` or `develop` except the release commit.
- Ask the owner before a release, a push to `main`, or anything public.

## Risks

- Scheme performance: if a keystroke path is too slow in Steel, the temptation is to move it to Rust. Measure first; prefer a faster primitive over moving behavior.
- Concurrency against live redefinition: one thread owns the VM and the editor ([[0012-one-thread-owns-the-vm-and-the-editor]]).
- Steel is young: expect missing builtins and rough errors; pin it and upgrade deliberately.
- Scope: a personal daily driver is achievable; an Emacs competitor is a multi-year community effort.

## References

- Helix and its Steel plugin branch: the closest prior art for the Rust/Scheme boundary (Helix's key grammar is Kakoune's, not Vim's).
- Lem: a Common Lisp editor with a vi-mode, closest in spirit.
- Evil: the edge cases of Vim emulation are documented in its source.
- Neovim: the behavior to match, and its grid UI protocol as a model for frames.
- The Xi-editor retrospective (CRDTs, RPC plugins) and Zed (Rust, GPU rendering, WASM, CRDTs done well).
