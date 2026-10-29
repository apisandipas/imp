---
type: Effort
status: active
specs: ["[[spec/auto-pairs]]"]
issue: https://github.com/apisandipas/imp/issues/83
frozen:
  docs/specs/auto-pairs.md: 96385e7355d2
---
# Bracket and quote pairs

## Approach

The first half of [[spec/auto-pairs]]; end tags are a second effort. Pairing is core insert behaviour, so it lives in `runtime/vim.scm` beside `smartindent`, called from `insert-key!` for a typed char and for `<bs>`. `emacs.scm` loads after it and calls the same functions from `self-insert!` and `delete-backward-char`, since a runtime file can't call into a later one. The pairs added in this insert are a list of closer positions, shifted as text is typed before them and dropped when insert mode ends or the cursor leaves the pair; step-over and `<bs>` only act on those. Undo and `.` need nothing new: the closer is inserted inside the insert's change, and `.` replays the typed keys through `insert-key!`. Modes set `auto-pairs-chars` locally from their `define-major-mode!` setup, as they set `commentstring`.

## Tasks

- [x] Pairs in insert mode, with step over and backspace (one task: without step-over, typing `(x)` gives `(x))`, which breaks tests that type code): options `auto-pairs` (on) and `auto-pairs-chars`; typing an opener adds its closer when the next char is white space, the end of the line, a closer or `, ; : .`; a quote not after a letter or digit; nothing in replace mode, from a paste or from `C-r`. REPL history matches the input less closers after the cursor, so the closer doesn't stop `(d` finding `(define ...)`. With tests, `docs/reference/ref-auto-pairs.md` written from the spec (in the Editing group), and a line in the README. Step over and backspace: typing a closer that pairing added in this insert steps over it, and `<bs>` in an empty such pair deletes both; a closer already in the buffer is typed, and `<bs>` there deletes one char; the pair is forgotten when insert mode ends or the cursor leaves it. Tests for these, for `u` undoing the pair with the insert, `.` repeating it, and `<ret>` inside `{}` with `smartindent`.
- [x] Quotes in strings and comments: a quote doesn't pair inside a string or comment by the syntax tree; with no tree only the letter-or-digit rule applies. Tests in Rust and Scheme buffers and a plain one.
- [x] Pairs per mode: programming modes pair all six, Rust leaves out `'`, Lisp modes (Scheme, Lisp, the REPL) pair brackets and `"`, text modes (Markdown, Org, plain text) brackets and `"`, Markdown also `` ` ``; inside a code fence the buffer's mode's pairs apply. Tests per mode, and `set-local-option!` changing them.
- [x] The Emacs state: pairs, step-over and `<bs>` (`delete-backward-char`) as in insert mode, undoing with the typing around them; an opener or quote with the region active wraps it, leaves the cursor after the closer, deactivates the region and undoes in one step. Tests, and the Emacs state spec and reference page pointing to auto pairs.
