---
type: Page
spec: "[[spec/showkeys]]"
frozen:
  docs/specs/showkeys.md: 8d44499288a6
---
# showkeys

## Floating boxes

A floating box is a few lines in a rounded border at a corner of the screen, or the middle of its top or bottom edge, drawn over your windows. Popups, menus and which-key are drawn over it, and it never takes keys or the cursor. It's there for packages and your own `init.scm`:

```scheme
(float-show! "clock"
             (list (list (list "12:00" "bold")))
             'top-right)
(float-hide! "clock")
```

Each line is a list of `(text face)` runs, as popups take. The positions are `'bottom-right`, `'bottom-left`, `'bottom-center`, `'top-right`, `'top-left` and `'top-center`. A top box starts on the first row; a bottom box ends above the bottom windows' status lines, so they stay readable. Showing a name again replaces its box, and boxes at the same position stack away from the edge.

A box too wide or tall for the screen is cut to fit. Its text is in the `float` face and its border in `float.border`, or the face you pass after the position; a theme that doesn't set them gets the popup's.

| Procedure | What it does |
|---|---|
| `(float-show! name lines position [border])` | Show the box `name`, replacing one of that name |
| `(float-hide! name)` | Remove it |
