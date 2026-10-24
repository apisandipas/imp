---
type: Effort
status: active
specs: ["[[spec/org]]"]
issue: https://github.com/apisandipas/imp/issues/42
frozen:
  docs/specs/org.md: 7615ff672a06
---
# Live table alignment

Keep Org tables aligned while typing in them.

## Approach

An `after-change` hook in Org buffers realigns the table at the cursor while in insert state, with `org-table-align!`, then puts the cursor back at the same place in its cell. The cell under the cursor is taken as typed up to the cursor, not trimmed, so a space typed before the next word survives; the realignment skips `begin-change!`, so the insert stays one undo step.

Decisions made while the owner was away (split from #15, which asked for that): realign on every key rather than only when the row overflows; only in insert state, not for normal-state edits such as `x`.

## Tasks

- [ ] Realign while typing in insert state, keeping the cursor, typed spaces and one undo step. Tested in `org.rs`.
