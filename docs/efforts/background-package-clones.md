---
type: Effort
status: active
specs: ["[[spec/packages]]"]
issue: https://github.com/apisandipas/imp/issues/13
frozen:
  docs/specs/packages.md: 13552394352f
---
# Background package clones

Clone a missing `'git` package as a job, and load it when the clone finishes.

## Approach

`use-package!` starts the clone (and the checkout of `'rev`) with `start-job!` instead of `run-shell`, marks the package `cloning`, and loads it from the job's exit callback. A failed checkout removes the directory the clone made, so a later start clones again instead of loading the wrong revision.

Decisions made while the owner was away (issue #13 had no answers yet): progress is a status line message at the start and end, not git's percentages; packages declared after one being cloned don't wait for it; `:package-update` stays synchronous.

## Tasks

- [ ] Clone in the background with status messages, load and run `'config` on success, report and clean up on failure. `packages.rs` tests a clone (pumping until it loads), the editor answering while it runs, and a failed clone.
