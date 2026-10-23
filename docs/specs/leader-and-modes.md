---
status: accepted
summary: "The SPC leader with which-key, and major and minor modes."
anchors: [runtime/leader.scm, runtime/modes.scm, crates/imp-server/tests/leader.rs, crates/imp-server/tests/modes.rs]
---
# Leader and modes

## Behaviour

- **Leader**: space in normal and visual mode, a Doom-like tree: files, buffers, eval, help, search, toggles, windows, quit, and `SPC m` for the major mode. Typing it shows a which-key popup of the next keys after `which-key-delay`, updated as keys are typed.
- **Major modes**: one per buffer, picked by file name when it opens, for about 20 languages; each sets indentation and its comment string. **Minor modes**: any number per buffer.
- Key lookup goes minor modes' keymaps, then the major mode's and its parents', then the state's. Insert mode checks mode keymaps first, so a mode can rebind `<ret>`.
- Mode key sequences that start with a control or meta key (`C-c C-c`) wait for the rest in normal, visual and insert state, without touching Vim's `g` and `z` prefixes or insert typing.
- `gc` comments with the mode's comment string. `:mode` sets the major mode.

## Keys and options

- `which-key-delay` (300 ms), `commentstring`.
- `(define-leader! "keys" command "description")`, `define-leader-group!`, `define-mode-leader!`; `define-major-mode!`, `define-minor-mode!`, `define-mode-key!`, `define-file-name-mode!`, `set-major-mode!`, `minor-mode-on!`, `set-local-option!`.
