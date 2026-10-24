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
- **Display**: soft wrap (on by default, as in Vim), `linebreak` to wrap between words, Unicode display width (wide chars take two cells, combining marks none), horizontal scrolling without wrap, line numbers (absolute, relative, hybrid), `cursorline`, `signcolumn`.
- **Frames**: only changed rows are sent and redrawn.
- **Special buffers**: generated buffers in `special-mode`, where `q` returns to where you were; `menu!` popups and `confirm!`; read-only buffers (`:set nomodifiable`).

## Keys and options

`window-divider-width`, `splitbelow`, `splitright`, `wrap`, `linebreak`, `number`, `relativenumber`, `cursorline`, `signcolumn`.

