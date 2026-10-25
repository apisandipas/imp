---
type: Effort
status: active
issue: https://github.com/apisandipas/imp/issues/59
specs: ["[[spec/org-agenda]]", "[[spec/org]]"]
frozen:
  docs/specs/org-agenda.md: 7188e85aaf98
  docs/specs/org.md: eacefd3dbd04
---
# Org agenda: acting on entries

## Approach

The second of six efforts for issue #59 ([[org-agenda]]): *Acting on entries*, without clocking (effort 5), and the Org-buffer commands it acts through ([[org]]): tags, effort, refile and archive.

Each Org command is written once, for the heading at a line of the current buffer, and bound in Org buffers. The agenda acts through the same commands: it goes to the entry's file buffer (opening it in the background if it isn't open), runs the command on the entry's heading, saves the buffer unless it had unsaved changes before, and comes back to redraw. Commands that ask for something (a date, a tag, a heading) ask in the agenda and act once answered. The agenda remembers the last change's buffer and version, so `u` can undo it there.

Each task updates the reference pages it changes (`ref-org`, `ref-org-agenda`) in the same commit.

## Tasks

- [x] Tags in Org buffers: `C-c C-q` (`SPC m q`) sets a heading's tags, completing from the agenda files' tags, an empty answer removing them; and effort: `C-c C-x e` (`SPC m c E`) sets its `Effort` property; with tests
- [x] Refile in Org buffers: `C-c C-w` (`SPC m r`) moves the heading and its subtree under any agenda-file heading, at the right level, as one undo step; with tests
- [x] Archive in Org buffers: `C-c C-x C-a` (`SPC m A`) moves the subtree to `org-archive-location` with the `ARCHIVE_*` properties, making the archive file, which the agenda doesn't read; with tests
- [x] Acting from the agenda: a change goes through the entry's file buffer, opened in the background if needed, saved unless it had unsaved changes, and the line redraws in place (an entry no longer in the view goes); `t` cycles the TODO keyword and `SPC m t` picks one; with tests
- [x] `SPC m d s` and `SPC m d d` schedule and set a deadline from the calendar; `H` and `L` move the line's date a day; with tests
- [x] `+` and `-` raise and lower the priority, `SPC m p` sets it; `ct` (`SPC m q`) sets tags, `ce` the effort; with tests
- [ ] `SPC m r` refiles, `da` archives asking first and `dA` without, `dd` deletes the entry and its subtree asking first; with tests
- [ ] `C` captures with the line's date; `u` undoes the last change made from the agenda; with tests
- [ ] Read the reference pages through against the specs and the keys, and check the which-key labels
- [ ] The owner has looked at acting from the agenda
