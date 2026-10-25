# tools

- `check.sh`: tests (also with every feature on), clippy (also the terminal-only build) and fmt; fails if any fail. Gate every commit on it, with `lore check`. It runs cargo inside `nix develop` when Nix is installed.
- `parens.py FILE.scm`: finds unbalanced brackets (Steel's parse errors don't say where).
- `docstrings.py missing` lists runtime functions without a docstring; `insert` adds them.
- `site-docs.py [OUT]` builds the website's docs section, `site/docs/` (ignored by git), from `docs/guide` and `docs/specs` with pandoc ([[0017-the-user-reference-is-generated-from-the-specs]]). Every spec must be in one of its `GROUPS`.
- `drive.py` drives the real binary in a pty (see its docstring); `shot.py` does the same and saves the screen as a PNG. Set `HOME` to a temporary directory so no user config loads.

## Releases

GPL-3.0-or-later. Pushing a `v*` tag runs `.github/workflows/release.yml`: a GitHub release (a prerelease for tags with a `-`) with binaries for x86_64 and aarch64 Linux and Apple-silicon macOS. To release, with the owner's go-ahead: merge `develop` into `main`, `make bump VERSION=x.y.z`, commit "Release x.y.z", `git tag -a vx.y.z -m 'imp x.y.z'`, push `main` and the tag, then merge `main` into `develop`. The release workflow takes about 15 minutes; CI's check job about 55. `ci.yml` runs `check.sh` (with Nix, and again with rustup alone, as people without Nix build) and `nix build` on pushes to `main` and `develop` and on pull requests.

## Disk

`target/` once reached 160 GB. Dependencies build without debug info and our crates with line tables only; run `make clean` when `target/` passes about 20 GB.
