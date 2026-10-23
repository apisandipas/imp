---
status: accepted
summary: "Evaluating Scheme in the running editor, the REPL, hooks and advice, and help from the source."
anchors: [runtime/core.scm, runtime/help.scm, runtime/modes.scm, crates/imp-server/src/docs.rs, crates/imp-server/tests/eval.rs, crates/imp-server/tests/help.rs, crates/imp-server/tests/hooks.rs]
---
# Live Scheme and help

The defining Emacs capability: change the editor while it runs, and ask it how it works.

## Behaviour

- **Evaluation**: `:eval EXPR`, `:source`, eval the form before the cursor, the top-level form, a region or the buffer, `M-:`, and `:messages`. A `define` of an existing name redefines it for every caller ([[steel]]).
- **REPL**: a `*scheme*` buffer (`:repl`, `SPC e i`).
- **Hooks and advice**: `add-hook!`, `remove-hook!`, `run-hooks`; `advice-add!` with `'before`, `'after` or `'around`, and `advice-remove!`. Every caller sees advice.
- **Named commands**: a key bound to a command name looks it up when pressed, so redefining the command changes every key bound to it.
- **Help from the source**: `describe-key` (press keys; see the binding form and its documentation), `describe-function`, `describe-option`, `describe-command`, `apropos`, `find-definition`, `:help`. In Scheme buffers `K` shows help and `gd` goes to the definition; without a language server `K` says what's missing elsewhere.
- **Docstrings** are a string first in a function's body or a command's lambda, as in Emacs; help reads them from the source.

## Keys and options

- `SPC e` evals, `SPC h` helps (`SPC h k` describe-key, `SPC h f` describe-function…).

## Known gaps

- The REPL has no input history.
- The `after-change` hook runs once per key, without the changed range.
