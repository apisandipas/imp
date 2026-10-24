---
type: Effort
status: active
specs: ["[[spec/org]]"]
issue: https://github.com/apisandipas/imp/issues/15
frozen:
  docs/specs/org.md: f060f1821a4a
---
# Org repeaters and properties

Repeating timestamps move on when their heading is marked done, headings' properties can be read and set, and the agenda shows each entry's category.

## Approach

All of it is Scheme in `runtime/org.scm`, with the date arithmetic `calendar.scm` already has. Timestamps are parsed into their parts (date, time, repeater, warning) once, so repeating, the calendar and the agenda share one reader rather than each slicing strings. Properties are read from lines of text, not the buffer, because the agenda reads files that aren't open; the buffer reader passes its own lines. Planned and built while the owner was away; the choices made are listed in the PR.

## Tasks

- [x] Parse a timestamp into date, time, repeater and warning, and write it back with its day name, with tests.
- [ ] Marking a heading done moves on its entry's repeating active timestamps (`+`, `++`, `.+`) and sets its keyword back to the first TODO keyword, with tests.
- [ ] Changing a repeating timestamp from the calendar keeps its repeater, with a test.
- [ ] `org-entry-property` reads a heading's property, with inheritance and `#+PROPERTY:`, with tests.
- [ ] `C-c C-x p` (`SPC m P`) sets or removes a property, making the drawer if needed, with tests.
- [ ] The agenda shows each entry's category, from `CATEGORY` or `#+CATEGORY:` or the file name, with a test.
- [ ] The file's header comment lists the new keys; the owner has tried repeaters and properties by hand.
