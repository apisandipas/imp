---
status: accepted
summary: "An Emacs editing state beside Vim's, toggled with C-z as in Evil."
anchors: [runtime/emacs.scm, crates/imp-server/tests/emacs.rs]
---
# Emacs state

People who want an Emacs-flexible editor often have Emacs habits, so Emacs keys are a supported state, not an afterthought.

## Behaviour

- An `emacs` state beside normal, insert and visual: keys insert text, and Emacs keys edit.
- Mark and region (`C-SPC`), a kill ring (`C-k C-w M-w C-y M-y`; kills also go to the unnamed register), `C-u` arguments, isearch (`C-s C-r`), `C-x` keys (`C-x C-s`, `C-x C-c`…), movement (`C-f C-b C-n C-p C-a C-e M-f M-b M-< M->`), `C-d M-d C-/ C-g M-x`.
- Brackets and quotes pair as in insert mode, and typing one with the region active wraps the region ([[spec/auto-pairs]]).
- Brackets and quotes pair as in insert mode, and typing one with the region active wraps the region ([[spec/auto-pairs]]).
- `C-z` toggles between Vim and Emacs state.
- Bind more with `(define-key! 'emacs "C-x C-s" 'save-buffer)`.

## Keys and options

- `editing-style`: `"vim"` (default) or `"emacs"`, the state imp starts in. Set it in `init.scm`.

## Out of scope

- Elisp, and Emacs's own packages.
