---
status: accepted
summary: "Clicks, drag to select, the wheel, and dragging borders."
anchors: [runtime/mouse.scm, crates/imp-server/tests/mouse.rs]
---
# Mouse

## Behaviour

- Click to move the cursor, focusing the window; drag to select; the wheel scrolls the window under it.
- Drag a border between side-by-side windows, or a status line with a window below, to resize.
- After a left click lands in a window's text, the `mouse-click` hook runs with the offset clicked (before normal mode keeps the cursor off a line's end), the clicked window current and the cursor moved, so a mode can act on the click (the file tree opens what is clicked, [[file-tree]]). A click on a fold's chevron, a border or a status line doesn't run it.
- Clicks land correctly on wrapped lines, concealed links, indented Org sections and tall lines.

## Keys and options

- `mouse` (`:set nomouse` turns it off; shift-drag still selects in most terminals while imp captures the mouse), `mouse-scroll`.
