---
status: accepted
issue: https://github.com/apisandipas/imp/issues/9
summary: "The SPC leader and Vim prefixes with which-key, and major and minor modes."
anchors: [runtime/leader.scm, runtime/modes.scm, "symbol:binding-label", "symbol:*prefix-which-key*", crates/imp-server/tests/leader.rs, crates/imp-server/tests/modes.rs]
---
# Leader and modes

## Behaviour

- **Leader**: space in normal and visual mode, a Doom-like tree: files, buffers, eval, help, search, toggles, windows, quit, and `SPC m` for the major mode, which always shows the current buffer's mode's keys, its groups named (`define-mode-leader-group!`). Typing it shows a which-key popup of the next keys after `which-key-delay`, updated as keys are typed. The popup has a blank line under its entries, so they don't sit on the command line.
- A count typed before `SPC` goes to the command the sequence runs: `2 SPC o t` is `toggle-terminal` with a count of 2.
- `<bs>` in a leader sequence takes back the last key typed and shows the popup for the keys before it, at once: `SPC g <bs>` is back at `SPC`. `<bs>` at `SPC` alone cancels the sequence, as `<esc>` does.
- **Vim prefixes**: `g`, `z`, `Z`, `[`, `]` and `C-w`, and any prefix declared with `define-prefix!`, show the same which-key popup after `which-key-delay` in normal and visual state, titled with the keys typed so far, count included (`3g`). It lists only keys imp binds after that prefix in the current state, the buffer's mode keys included; a mode key's label wins over a Vim key of the same name. Each entry shows the key's label, else the name of the command it is bound to, else nothing beside the key. The popup closes when the next key is typed or the prefix is cancelled. `"` and char motions such as `f` show no popup, nor does operator-pending state (`dg`, `gu`).
- **Major modes**: one per buffer, picked by file name when it opens, for about 20 languages; each sets indentation and its comment string. **Minor modes**: any number per buffer.
- The buffer's **mode keys** are its minor modes' keymaps, then its major mode's and its parents', then the `:map` mappings ([[spec/vim]]), looked in in that order. Insert mode checks mode keys before its own, so a mode can rebind `<ret>`.
- **Which binding a key runs** in normal and visual state (key resolution): once any count, register and prefix are typed, the key runs the first of these that binds it.
  - Normal state: a mode key, an operator, a motion, a normal key, a char command (`r`).
  - Visual state: a mode key, a visual key, an operator, a text object, a char command, a motion.
  - With an operator pending, only a motion, a text object or the operator again (`dd`, `gUU`) is looked for; mode keys aren't.
  - A mode key also takes a digit, `/`, `?` or a prefix key (`g`, `z`) from Vim when no operator is pending (and, for a digit, no count is being typed): the start screen's `1`, the git status buffer's `?`, special buffers' `q`.
- Which-key, `describe-key` ([[spec/live-scheme-and-help]]) and `:map` ([[spec/vim]]) use the same rule, so what they report is the binding that would run here: in visual state which-key lists text objects and char commands as well.
- Mode key sequences that start with a control or meta key (`C-c C-c`) wait for the rest in normal, visual and insert state, without touching Vim's `g` and `z` prefixes or insert typing. So do a mode's sequences that start with a letter other than Vim's prefixes, as the agenda's `ct` and `dd`, in normal and visual state: while the buffer's modes bind longer keys starting with it, that key waits for the rest instead of being Vim's.
- `gc` comments with the mode's comment string. `set-major-mode` asks for a major mode and sets it; the current one is offered first.

## Keys and options

- `which-key-delay` (300 ms), `commentstring`.
- `(define-leader! "keys" command "description")`, `define-leader-group!`, `define-mode-leader!`; `define-major-mode!`, `define-minor-mode!`, `define-mode-key!`, `define-file-name-mode!`, `set-major-mode!`, `minor-mode-on!`, `set-local-option!`.
- `define-key!`, `define-motion!`, `define-operator!` and `define-mode-key!` take an optional last argument, the label which-key shows; imp's own Vim keys have labels.
- `(resolve-key state key [operator])`, with `state` `'normal` or `'visual`, gives the binding `key` runs by the rule above, with `operator` pending if given: a binding record of its kind (`mode-key`, `visual-key`, `operator`, `text-object`, `motion`, `normal-key`, `char-command`, `operator-again` or `prefix`), the procedure it runs, its which-key label and, for a named command, the command's name. A prefix key alone (`g`) is a `prefix`; a key that does nothing gives `#f`.

## Out of scope

- Which-key in operator-pending state, for registers (`"`), and for char motions.
- `<bs>` after a Vim prefix (`g`, `z`, `C-w`): those are one key deep, so there is no level to go back to.
- Vim keys imp does not bind; the popup never lists a key that would do nothing.
- An option to turn the Vim-prefix popup off apart from the leader's; a large `which-key-delay` delays both.
- Key resolution in insert, replace and Emacs state, which look up keys their own simpler way.
- Changing which binding wins: the rule above is the order keys already ran in; only what which-key, `describe-key` and `:map` report follows it now.
