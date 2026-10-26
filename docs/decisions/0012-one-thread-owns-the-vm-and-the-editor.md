---
type: Decision
status: accepted
anchors: ["crates/imp-server/src/editor.rs", "crates/imp-server/src/events.rs"]
---
# One thread owns the VM and the editor

## Context
Live redefinition is only safe if nothing runs Scheme or reads editor state while a definition changes. LSP, jobs, timers and file watching all happen in the background.

## Decision
One thread owns the Steel VM and all editor state. Everything else (jobs, timers, language servers, clients) posts events to its loop. Editor state is a `thread_local`, because Steel's `register_fn` takes plain functions.

## Consequences
- No locks around editor state, and redefining anything live stays safe.
- One server per thread: tests must not run two servers at once on one thread.
- Slow work has to be split off as a job and its result handed back as an event.
