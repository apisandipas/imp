# tools

- `check.sh`: tests (also with every feature on), clippy (also the terminal-only build) and fmt; fails if any fail. Gate every commit on it, with `lore check`. It runs cargo inside `nix develop` when Nix is installed.
- `parens.py FILE.scm`: finds unbalanced brackets (Steel's parse errors don't say where).
- `docstrings.py missing` lists runtime and package functions without a docstring, and options without a comment above; `insert` adds docstrings.
- `site-docs.py [OUT]` builds the website's docs section, `site/docs/` (ignored by git), from `docs/guide` and `docs/reference` with pandoc ([[0018-user-reference-pages-are-written-from-the-specs-and-checked]]). Every spec must be in one of its `GROUPS`. `--check` also fails when a spec changed since a reference page or a guide that summarises it was written; `--stamp NAME` and `--stamp-guide NAME` record that one is up to date again.
- `drive.py` drives the real binary in a pty (see its docstring); `shot.py` does the same and saves the screen as a PNG. Set `HOME` to a temporary directory so no user config loads.

## Releases

GPL-3.0-or-later. Pushing a `v*` tag runs `.github/workflows/release.yml`: it builds binaries for x86_64 and aarch64 Linux and Apple-silicon macOS with a read-only token, then, only if every build passed, one job with write access makes the GitHub release (a prerelease for tags with a `-`) with them attached. To release, with the owner's go-ahead: merge `develop` into `main`, `make bump VERSION=x.y.z`, commit "Release x.y.z", `git tag -a vx.y.z -m 'imp x.y.z'`, push `main` and the tag, then merge `main` into `develop`. The release workflow takes about 15 minutes; CI's check job about 55. `ci.yml` runs `check.sh` (with Nix, and again with rustup alone, as people without Nix build), `nix build`, and `lore check` with `site-docs.py --check` (the docs job, which downloads a pinned lore release) on pushes to `main` and `develop` and on pull requests.

The workflows' tokens are read-only unless a job needs more. Every third-party action is pinned to a commit SHA with its version in a comment; to update one, look up the new tag's commit (`gh api repos/OWNER/REPO/commits/TAG -q .sha`). The Rust version in `ci.yml` and `release.yml` follows `flake.lock`; bump all three together.

## Disk

`target/` once reached 160 GB. Dependencies build without debug info and our crates with line tables only; run `make clean` when `target/` passes about 20 GB.
