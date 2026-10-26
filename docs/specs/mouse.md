---
status: accepted
summary: "Clicks, drag to select, the wheel, and dragging borders."
anchors: [runtime/mouse.scm, crates/imp-server/tests/mouse.rs]
---
# Mouse

## Behaviour

- Click to move the cursor, focusing the window; drag to select; the wheel scrolls the window under it.
- Drag a border between side-by-side windows, or a status line with a window below, to resize.
- Clicks land correctly on wrapped lines, concealed links, indented Org sections and tall lines.

## Keys and options

- `mouse` (`:set nomouse` turns it off; shift-drag still selects in most terminals while imp captures the mouse), `mouse-scroll`.
