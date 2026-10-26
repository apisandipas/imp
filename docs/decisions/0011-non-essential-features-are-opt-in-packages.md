---
type: Decision
status: accepted
anchors: ["packages/**", "crates/imp-server/src/lib.rs"]
---
# Non-essential features are opt-in packages

## Context
As the ecosystem grew, the runtime gained features that not everyone wants, and every one of them loads at startup and widens what a change can break.

## Decision
What isn't essential to editing is a package in `packages/NAME/NAME.scm`, listed in `PACKAGES` in `crates/imp-server/src/lib.rs`, and loads only with `(use-package! 'NAME)`. Core gets only the primitive the package can't do without.

## Consequences
- New optional features start as packages.
- Some runtime files from the Phase 6 ecosystem (git, org, dired) predate the rule and are candidates to move.
