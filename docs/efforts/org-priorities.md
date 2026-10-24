---
type: Effort
status: done
specs: ["[[spec/org]]"]
issue: https://github.com/apisandipas/imp/issues/44
frozen:
  docs/specs/org.md: 70a1f9867895
---
# Org priorities

Set, show and sort by Org priorities.

## Approach

The cookie lives in the heading text, after the keyword, as Org writes it; `org-heading-title` already skips it. Setting it rebuilds the heading line from its parts, as cycling the TODO keyword does. Agenda entries gain their priority, and both lists sort by it after the date, keeping file order between equals.

Decisions made while the owner was away (split from #15): priorities A to C with B as the default, as Org's defaults; a menu for setting it rather than `S-<up>`/`S-<down>`, which the clients don't send as distinct keys.

## Tasks

- [x] `C-c ,` and `SPC m p` set or remove the priority, the cookie has a face, and the agenda sorts by priority. Tested in `org.rs`.
