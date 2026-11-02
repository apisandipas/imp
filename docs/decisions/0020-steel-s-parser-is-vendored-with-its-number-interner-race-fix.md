---
type: Decision
status: accepted
anchors: ["vendor/steel-parser/src/tokens.rs"]
---
# Steel's parser is vendored with its number interner race fixed

## Context

steel-parser 0.8.3 interns every number literal in one process-wide table, `NUMBER_INTERNER`, which `add` fills by inserting the key and then the value. A thread that interns the same new number in between finds the key, gets its id, and panics in `resolve` (`tokens.rs:153`) because the value isn't there yet. imp runs one VM on one thread ([[0012-one-thread-owns-the-vm-and-the-editor]]), so the editor never hits it, but the tests run a server per thread and failed CI now and then (#98). A test that pauses one thread between the two inserts reproduces it every time; with the inserts swapped it passes.

Numbers aren't interned only when source is lexed: constant folding, code generation and the conversions between values and syntax intern them too, so no lock imp could put around parsing covers every path. Locking all of Steel's work would run the tests one at a time. Loading the first test server alone (PR #107) only narrowed the window. 0.8.3 is the latest release, and Steel's master has the same code. A fork on GitHub would be public, and a report upstream needs the owner's go-ahead.

## Decision

imp builds against a copy of steel-parser 0.8.3 in `vendor/steel-parser`, through `[patch.crates-io]` in the root `Cargo.toml`, changed only to insert the value before the key. A key, once found, then always resolves. The copy is excluded from the workspace, so it isn't linted, formatted or tested with imp's crates.

## Consequences

- The race is gone for the tests and anything else that runs Steel on several threads, and the test helper no longer loads its first server alone.
- Upgrading Steel means checking whether the new steel-parser still needs the patch: drop the copy if it fixes the race, or copy the new version and patch it again. `vendor/CONTEXT.md` says how.
- `cargo install --git` and the Nix build use the patched copy too; both build from the repository.
