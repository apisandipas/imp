---
type: Effort
status: done
specs: ["[[spec/leader-and-modes]]"]
frozen:
  docs/specs/leader-and-modes.md: 6f6173563533
---
# Backspace goes back a which-key level

## Approach

Issue #65. `leader-input!` in `runtime/leader.scm` handles `<bs>` before looking the keys up: it drops the last key of `*leader-keys*` (by `split-keys`, so `<tab>` goes whole) and shows that level's popup at once, skipping `which-key-delay`; with no keys left it ends the sequence as `<esc>` does. The Vim prefixes are left alone.

## Tasks

- [x] `<bs>` in a leader sequence goes back one key and shows that level's popup at once; at `SPC` alone it cancels, with a test in `crates/imp-server/tests/leader.rs`
- [x] The leader reference page says so, restamped
