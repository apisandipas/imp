---
type: Page
spec: "[[spec/overlays]]"
frozen:
  docs/specs/overlays.md: bc97912d2e13
---
# Popups and menus

The which-key popup, menus, completion menus, describe pages and y/n questions all open over your windows for a moment. imp calls each of these an overlay. One is open at a time: opening another closes the one before.

## How they behave

- A new overlay replaces the open one. A popup that only shows something, such as hover help or git output, doesn't take the place of a menu or the leader while you're typing into it. It waits, and opens when they close.
- A describe or output popup closes on the next key. `<esc>`, `<ret>`, space and `C-c` only close it; any other key also does what it usually does.
- A long list you move through shows at most 10 rows, fewer in a short window, and scrolls to keep the selected line in view. A describe or output popup shows all its lines.
- A mouse click closes a completion menu or an output popup. A menu or the leader ignores clicks until you finish it.

## Showing your own

For a popup that the next key closes, call `show-popup!` with a list of lines. Each line is a list of `(text face)` pieces:

```scheme
(show-popup! (list (list (list "Hello" "bold"))
                   (list (list "from init.scm" ""))))
```

For a menu of keys, use `menu!`. Each entry is a key, a label and what to run:

```scheme
(menu! "Greet"
       (list (list "h" "hello" (lambda () (message "hello")))
             (list "b" "goodbye" (lambda () (message "goodbye")))))
```

`confirm!` asks a y or n question on the message line, and runs what you give it on `y`:

```scheme
(confirm! "Say hello?" (lambda () (message "hello")))
```

Lines given after it show in a popup above the question, and close with it.

## Overlays of your own

`overlay-open!` opens an overlay with a name, its lines, and options given as pairs:

```scheme
(overlay-open! 'colors
               (list (list (list "red" "")) (list (list "green" "")))
               'title "Colors"
               'selected 0
               'keys (lambda (key) (if (equal? key "<esc>") (begin (overlay-close! 'colors) #t) #f))
               'on-close (lambda () (message "closed")))
```

| Option | Default | What it does |
|---|---|---|
| `'place` | `'bottom` | `'bottom`, `'cursor` or `'center` |
| `'column` | `0` | With `'cursor`, how far from the cursor's column it starts |
| `'width` | `60` | With `'center`, the percent of the screen it takes |
| `'title` | `""` | The title in its rule or border |
| `'selected` | `#f` | The selected line, counting from 0 |
| `'keys` | none | Called with each key while it's open. Return `#f` to let the key do what it usually does |
| `'on-close` | none | Runs once when it closes, whatever closes it |
| `'click-closes` | `#f` | Whether a mouse click closes it |
| `'count` | | When the lines are a procedure, how many there are |

The lines can also be a procedure `(lambda (top rows) ...)` that returns only the rows shown, starting at line `top`. Give `'count` with it. A list of thousands of items then costs no more than the ten shown.

| Procedure | What it does |
|---|---|
| `(overlay-open! name lines option value ...)` | Open `name`, closing the one open |
| `(overlay-update! name lines option value ...)` | Change its lines and any options given, if it's open |
| `(overlay-close! name)` | Close it, if it's the one open |
| `(overlay-open? [name])` | Whether `name`, or any overlay, is open |
