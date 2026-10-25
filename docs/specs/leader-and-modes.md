---
status: accepted
issue: https://github.com/apisandipas/imp/issues/9
summary: "The SPC leader and Vim prefixes with which-key, and major and minor modes."
anchors: [runtime/leader.scm, runtime/modes.scm, "symbol:binding-label", "symbol:*prefix-which-key*", crates/imp-server/tests/leader.rs, crates/imp-server/tests/modes.rs]
---
# Leader and modes

## Behaviour

- **Leader**: space in normal and visual mode, a Doom-like tree: files, buffers, eval, help, search, toggles, windows, quit, and `SPC m` for the major mode, which always shows the current buffer's mode's keys, its groups named (`define-mode-leader-group!`). Typing it shows a which-key popup of the next keys after `which-key-delay`, updated as keys are typed. The popup has a blank line under its entries, so they don't sit on the command line.
- `<bs>` in a leader sequence takes back the last key typed and shows the popup for the keys before it, at once: `SPC g <bs>` is back at `SPC`. `<bs>` at `SPC` alone cancels the sequence, as `<esc>` does.
- **Vim prefixes**: `g`, `z`, `Z`, `[`, `]` and `C-w`, and any prefix declared with `define-prefix!`, show the same which-key popup after `which-key-delay` in normal and visual state, titled with the keys typed so far, count included (`3g`). It lists only keys imp binds after that prefix in the current state, the buffer's mode keys included; a mode key's label wins over a Vim key of the same name. Each entry shows the key's label, else the name of the command it is bound to, else nothing beside the key. The popup closes when the next key is typed or the prefix is cancelled. `"` and char motions such as `f` show no popup, nor does operator-pending state (`dg`, `gu`).
- **Major modes**: one per buffer, picked by file name when it opens, for about 20 languages; each sets indentation and its comment string. **Minor modes**: any number per buffer.
- Key lookup goes minor modes' keymaps, then the major mode's and its parents', then the state's. Insert mode checks mode keymaps first, so a mode can rebind `<ret>`.
- Mode key sequences that start with a control or meta key (`C-c C-c`) wait for the rest in normal, visual and insert state, without touching Vim's `g` and `z` prefixes or insert typing. So do a mode's sequences that start with a letter other than Vim's prefixes, as the agenda's `ct` and `dd`, in normal and visual state: while the buffer's modes bind longer keys starting with it, that key waits for the rest instead of being Vim's.
- `gc` comments with the mode's comment string. `:mode` sets the major mode.

## Keys and options

- `which-key-delay` (300 ms), `commentstring`.
- `(define-leader! "keys" command "description")`, `define-leader-group!`, `define-mode-leader!`; `define-major-mode!`, `define-minor-mode!`, `define-mode-key!`, `define-file-name-mode!`, `set-major-mode!`, `minor-mode-on!`, `set-local-option!`.
- `define-key!`, `define-motion!`, `define-operator!` and `define-mode-key!` take an optional last argument, the label which-key shows; imp's own Vim keys have labels.

## Out of scope

- Which-key in operator-pending state, for registers (`"`), and for char motions.
- `<bs>` after a Vim prefix (`g`, `z`, `C-w`): those are one key deep, so there is no level to go back to.
- Vim keys imp does not bind; the popup never lists a key that would do nothing.
- An option to turn the Vim-prefix popup off apart from the leader's; a large `which-key-delay` delays both.
