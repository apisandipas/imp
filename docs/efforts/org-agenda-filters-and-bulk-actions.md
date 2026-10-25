---
type: Effort
status: active
issue: https://github.com/apisandipas/imp/issues/59
specs: ["[[spec/org-agenda]]", "[[spec/org]]"]
frozen:
  docs/specs/org-agenda.md: b6ab81427154
  docs/specs/org.md: eacefd3dbd04
---
# Org agenda: filters and bulk actions

## Approach

The fourth of six efforts for issue #59 ([[org-agenda]]): *Filters* and *Bulk actions*. Efforts 4–6 are built in parallel and shipped as one PR, at the owner's request.

Filters are predicates over agenda entries, kept in a buffer-local list that `org-render-agenda!` applies after the restriction, so they last through moving, redrawing and view changes; the title line shows them. Marks are a set of entry keys (file, line, keyword, title), drawn in the mark column with the marked face; bulk actions run the existing acting procedures (`org-agenda-act!`) on each marked entry, asking for the value once. Each task updates the reference page in the same commit; tests go in `crates/imp-server/tests/org_agenda_bulk.rs`.

## Tasks

- [x] Filters `sc` (category), `st` (tag, `-tag` to exclude, completing), `se` (effort comparison), `sr` (title regexp), `s^` (top-level heading), adding up, shown as `Filter: …` in the title, kept through moving, `gr` and `gD`, empty sections left out, `S` clears them; with tests
- [x] Marks: `m` toggles and moves down, `~` toggles all, `*` marks all, `%` marks by title regexp, `M` unmarks all; the mark column and the marked face (every bundled theme, Modus included); with tests
- [x] `x`, the bulk menu: `t` keyword, `s` schedule, `d` deadline, `+` and `-` tags, `r` refile, `$` archive, `S` shift dates by N days, `k` delete; asks once, acts on each marked entry, clears the marks; with tests
- [x] Read the reference page through against the spec and the keys, and check the which-key labels
- [ ] The owner has looked at it
