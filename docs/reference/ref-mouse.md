---
type: Page
spec: "[[spec/mouse]]"
frozen:
  docs/specs/mouse.md: 9395bb30b70d
---
# Mouse

imp works with the mouse as well as the keyboard. You can click, select, scroll and resize windows.

## Clicking and selecting

Click to move the cursor there. If the click is in another window, that window gets the focus.

Drag to select text. Clicks land on the right spot on wrapped lines, links shown as their descriptions, indented Org sections and tall lines.

## Scrolling

The wheel scrolls the window under the mouse, even if it isn't the one you're typing in. `mouse-scroll` sets how many lines each step moves.

## Resizing windows

Drag the border between two side-by-side windows to change their widths. Drag a status line that has a window below it to change their heights.

## Turning it off

`:set nomouse` makes imp ignore the mouse. While imp uses the mouse, most terminals still let you select text by holding shift as you drag.

## Options

| Option | Default | What it does |
|---|---|---|
| `mouse` | `#t` | Use the mouse |
| `mouse-scroll` | `3` | Lines the wheel scrolls per step |
