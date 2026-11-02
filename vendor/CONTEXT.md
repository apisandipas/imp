# vendor

Patched copies of dependencies, used through `[patch.crates-io]` in the root `Cargo.toml` and excluded from the workspace. They are not imp's code: don't lint, reformat or refactor them, so a diff against the release stays the patch alone.

- `steel-parser`: steel-parser 0.8.3 from crates.io (Steel commit 11a57adc), with `NumberLiteralInterner::add` in `src/tokens.rs` inserting the value before the key (#98, [[0020-steel-s-parser-is-vendored-with-its-number-interner-race-fix]]). Otherwise it is the release as published, less `Cargo.toml.orig`, `Cargo.lock` and cargo's bookkeeping files.

## Upgrading Steel

When `steel-core` moves to a new version, look at the new steel-parser's `add`. If it inserts the value first (or no longer has two maps), delete `vendor/steel-parser` and its `[patch.crates-io]` entry. Otherwise copy the new release here and apply the same change.
