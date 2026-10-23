---
type: Decision
status: accepted
anchors: [".lore/**"]
---
# Project notes in lore

## Context
Everything about imp lived in one 972-line `docs/HANDOFF.md` plus a design note per phase. Each session read all of it, much of it was history, and its rules were easy to miss. Outside feedback also said imp was being built far too fast.

## Decision
imp's notes are lore notes: Decisions in `docs/decisions`, Specs in `docs/specs`, Efforts in `docs/efforts`, and a `CONTEXT.md` per directory. `.lore/WORKFLOW.md` sets the process. HANDOFF.md and the phase notes are retired. Work is tracked in GitHub Issues.

## Consequences
- `lore context` shows the notes that govern a file before it is edited, instead of one long read.
- Features go through spec, plan, build and ship with the owner's approval at the spec and the plan, which slows the pace on purpose.
- Small work skips the flow.
