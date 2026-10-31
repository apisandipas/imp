---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/123
summary: "One owner for what opens over the windows for a moment, the popup and the keys it takes: which-key, menus, completion menus, show-and-close popups, prompts."
---
# Overlays

An overlay is something that opens over the windows for a moment: the which-key popup, a `menu!`, the insert completion menu, a describe popup, a y/n prompt. One overlay is open at a time, and one owner, in Scheme, keeps it: its lines, selection, place and title, the keys it takes, and closing it when another opens. The Rust popup slot and key interceptor it draws on stay as they are ([[decision/0005-rust-owns-data-and-speed-scheme-owns-behavior]]).

## Behaviour

### Which overlays

- The owner keeps every user of the popup and of the key interceptor: which-key for the leader, Vim prefixes and Emacs prefixes ([[spec/leader-and-modes]]); `menu!` and `confirm!` ([[spec/buffers-and-windows]]); the insert completion menu and the C-x completion keys; the command-line menu and the wildmenu; completing-read; the calendar; `show-popup!` (describe pages, LSP hover, git output, `:marks`, `:reg`...); describe-key; the file tree's help.
- Overlays opened while the command line is open (completing-read, the calendar, the command-line menu, the wildmenu) give the owner their rows; their keys still come through the command line, as now.

### Opening, replacing and closing

- `(overlay-open! name lines option value ...)` opens the overlay `name` (a symbol) with `lines`, each a list of `(text face)` runs as popups take. The options are given as pairs, as `use-package!` takes them:
  - `'place`: `'bottom` (default), `'cursor` or `'center`; `'column` is the offset from the cursor's column for `'cursor`, and `'width` the percent of the screen for `'center`.
  - `'title`: shown in the popup's rule or border; none by default.
  - `'selected`: the index of the selected line, or `#f` (default) for none.
  - `'keys`: a procedure called with each key while the overlay is open. It returns `#t` when it used the key up, and `#f` to let the key go on as if no overlay were open.
  - `'on-close`: a procedure of no arguments called once when the overlay closes, whatever closes it.
  - `'click-closes`: whether a mouse click closes it; `#f` by default.
- Opening an overlay sets every one of these; nothing is kept from the overlay before. A popup's place, title and selection never come from another overlay.
- One overlay is open at a time. Opening one while another is open closes the other first, and its `'on-close` runs.
- A `show-popup!` popup opened while an overlay with `'keys` is open waits instead, and opens when that overlay closes. Only the last waiting popup is kept. So a hover or git output that arrives late doesn't take the leader's or a menu's popup away.
- `(overlay-update! name lines [selected])` changes the open overlay's lines and selection, and does nothing if `name` isn't open.
- `(overlay-close! name)` closes `name` if it is open, runs its `'on-close`, and does nothing otherwise, so one overlay never closes another's.
- `(overlay-open? name)` says whether `name` is the open overlay; `(overlay-open?)` whether any is.

### Keys

- While an overlay with `'keys` is open, a key goes to its procedure before anything else but a macro recording's `q`. A key it doesn't use goes on as usual.
- A `show-popup!` popup closes on the next key; `<esc>`, `<ret>`, space and `C-c` only close it, and any other key goes on as usual. This is what it does now.
- `confirm!` is an overlay with no lines: its question is on the message line. dired's `:w`, which shows the changes and then asks y or n, is one overlay: `<esc>` closes the popup and the question together.
- The C-x completion keys and describe-key take keys as overlays with no lines.

### Scrolling

- An overlay given more lines than fit shows a window of them around the selected line: at most 10 rows, and no more than the window height less 2. The window moves only as far as it must to keep the selected line in view. The insert completion menu, the command-line menu and completing-read scroll this way.

### Mouse

- While an overlay is open, a mouse click closes it if it was opened with `'click-closes`. Otherwise a click is ignored while the overlay takes keys, and goes on as usual while it doesn't (a Vim prefix's which-key). The insert completion menu and `show-popup!` popups close on a click, as now.

### Names kept

- `show-popup!`, `menu!` and `confirm!` keep their arguments and what they do, built on the owner.
- `*key-interceptor*` stays, for snippet placeholders: a key goes to the open overlay first, then to it, then on as usual. Only snippet placeholders set it.

## Keys and options

- `(overlay-open! name lines option value ...)`, `(overlay-update! name lines [selected])`, `(overlay-close! name)`, `(overlay-open? [name])`.
- `show-popup!`, `close-popup!`, `menu!`, `confirm!`.

## Out of scope

- Snippet placeholders: they last while the snippet is edited, a mode rather than an overlay, and keep their own key handling. The completion menu opens over them without taking their keys away.
- More than one overlay at a time, or overlays stacked to come back when the one above closes.
- Floating boxes (`float-show!`, [[spec/showkeys]]): several can be shown at once, and they take no keys.
- How the command line reads keys.
- How the popup is drawn, which stays in Rust, and overlays across daemon clients.
- Any change to what an overlay looks like or which keys it takes, except as said above.

## Known gaps
