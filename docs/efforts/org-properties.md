---
type: Effort
status: done
specs: ["[[spec/org]]"]
issue: https://github.com/apisandipas/imp/issues/15
frozen:
  docs/specs/org.md: 7120a0ea277d
---
# Org properties

Headings' properties can be read and set, and the agenda shows each entry's category.

## Approach

Scheme in `runtime/org.scm`. Properties are read from a list of lines, not the buffer, because the agenda reads files that aren't open; the buffer reader passes the buffer's lines. The drawer is the one directly under the heading and its planning line, as Org requires; a `:PROPERTIES:` drawer further down the body isn't a property drawer. Setting a property goes through the buffer, as one undo step.

## Tasks

- [x] `org-entry-property` reads a heading's property, ignoring case, with inheritance through ancestors and `#+PROPERTY:`, with tests.
- [x] `C-c C-x p` (`SPC m P`) sets a property, completing names from the buffer, making the drawer after the planning line if needed; an empty value removes it, with tests.
- [x] The agenda shows each entry's category, from `CATEGORY` (inherited), `#+CATEGORY:` or the file name without `.org`, with a test.
- [x] The agenda lists entries dated after its span under `Later`, by date, once each, with a test.
- [x] The file's header comment lists `C-c C-x p`; the owner has tried properties by hand.
