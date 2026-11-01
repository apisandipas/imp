---
status: accepted
summary: "Buffers, split windows, popup windows, wrap and Unicode width."
anchors: [crates/imp-server/src/layout.rs, crates/imp-server/src/render.rs, runtime/special.scm, crates/imp-server/tests/buffers.rs, crates/imp-server/tests/windows.rs, crates/imp-server/tests/popup.rs, crates/imp-server/tests/render.rs]
---
# Buffers and windows

## Behaviour

- **Buffers**: `:e :e! :enew :ls :b :bn :bp :bd C-^ :wa :qa`, each with its own cursor and scroll; jumps cross buffers. A path too long for `:ls` is shortened from the start, keeping the file name, as the status line does.
- **Windows**: a split tree owned by the server. `C-w s v n w W h j k l c q o = + - < >`, `:sp :vs :new :vnew :close :only`, `:q` closing a window when there are several, `SPC w`. Each window has its own status line; the bottom row is the message line, or the command line while typing. A window's cursor is a buffer mark while it isn't focused, so edits through another window keep it in place.
- **Borders**: side-by-side windows are separated by a divider as wide as `window-divider-width` (logical pixels) in the window client, one column in a terminal. Drag it, or a status line, to resize.
- **Popup windows**: a generated buffer whose name matches a rule (`define-popup-rule!`) opens along an edge of the frame: `*grep*` along the bottom, `*git…*`, `*faces*` and `*capture*` down the right. `q` closes it, a file opened from it opens in the window it came from, and a popup opened from a popup reuses its window.
- **Display**: soft wrap (on by default, as in Vim), `linebreak` to wrap between words, Unicode display width (wide chars take two cells, combining marks none), control chars drawn as Vim draws them, never sent to a terminal raw (C0 but tab, and DEL, in caret notation, `^[` `^G` `^?`, two cells; C1 as `<9b>`, four; one char to the cursor; in buffer text, status lines, messages and popups alike), horizontal scrolling without wrap, line numbers (absolute, relative, hybrid; a buffer that sets `number` or `relativenumber` locally keeps its own in its window whichever window is focused), `cursorline`, `signcolumn`, and a one-cell change column between the line numbers and the fold column for a buffer given one with `set-change-marks!` (git-gutter's bars, [[0016-git-changes-take-their-own-gutter-column-not-the-sign-column]]).
- **Frames**: only changed rows are sent and redrawn.
- **End-of-line text**: a buffer can have text drawn after the end of a line, two cells past its last char, in a face (`set-line-end-text!`, one per line, by line number; it doesn't follow edits). It isn't part of the text: the cursor can't go there, and it's cut at the window's edge. On a wrapped line it follows the last row; on a closed fold's line it isn't drawn.
- **Footers**: a buffer can have footer lines, made of (text face) parts (`set-footer!`), pinned at the bottom of each window showing it, above its status line, however far the window scrolls. They take rows from the text, aren't part of it (the cursor can't go there, a click on them does nothing), and are cut to the window's width; a window with fewer than two rows of text beside them leaves them out.
- **Special buffers**: generated buffers in `special-mode`, where `q` returns to where you were; `menu!` popups and `confirm!` ([[spec/overlays]]); read-only buffers (`:set nomodifiable`).

## Keys and options

`window-divider-width`, `splitbelow`, `splitright`, `wrap`, `linebreak`, `number`, `relativenumber`, `cursorline`, `signcolumn`.

