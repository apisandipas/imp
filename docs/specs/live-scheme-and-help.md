---
status: accepted
issue: https://github.com/apisandipas/imp/issues/14
summary: "Evaluating Scheme in the running editor, the REPL, hooks and advice, and help from the source."
anchors: [runtime/core.scm, runtime/help.scm, runtime/repl.scm, crates/imp-server/src/docs.rs, crates/imp-server/tests/eval.rs, crates/imp-server/tests/help.rs, crates/imp-server/tests/hooks.rs]
---
# Live Scheme and help

The defining Emacs capability: change the editor while it runs, and ask it how it works.

## Behaviour

- **Evaluation**: `:eval EXPR`, `:source`, eval the form before the cursor, the top-level form, a region or the buffer, `M-:`, and `:messages` (the last 200 messages; echoes of keys being typed aren't kept). A `define` of an existing name redefines it for every caller ([[steel]]). A definition shows the name it defines; code with no value (a function called for its effect) shows nothing, leaving any message it showed.
- **REPL**: a `*scheme*` buffer (`:repl`, `SPC e i`). `<ret>` at the end evaluates the input after the last prompt and prints the result and a new prompt.
- **REPL history**: `M-p` and `M-n`, in insert and normal state, replace the input with the previous or next one. `<up>` and `<down>` do the same in insert state while the cursor is on the last prompt's line, and move between lines elsewhere. As on the command line, they visit only entries that start with what was typed before the first step, and stepping past the newest brings that text back. Each non-blank input is kept whole, multi-line ones included; an earlier copy of the same input is dropped. The newest 200 are kept in `repl-history` in the state directory, so history lasts across sessions; a state directory that can't be read or written is ignored.
- **Hooks and advice**: `add-hook!`, `remove-hook!`, `run-hooks`; `advice-add!` with `'before`, `'after` or `'around`, and `advice-remove!`. Every caller sees advice.
- **Named commands**: a key bound to a command name looks it up when pressed, so redefining the command changes every key bound to it.
- **Help from the source**: `describe-key` (press keys; see the binding form and its documentation), `describe-function`, `describe-option`, `describe-command`, `apropos`, `find-definition`, `:help`. In Scheme buffers `K` shows help and `gd` goes to the definition; without a language server `K` says what's missing elsewhere.
- **Docstrings** are a string first in a function's body or a command's lambda, as in Emacs; help reads them from the source.

## Keys and options

- `SPC e` evals, `SPC h` helps (`SPC h k` describe-key, `SPC h f` describe-function…).

## Out of scope

- Searching REPL history (`M-r` in Emacs), and a history per project.

## Known gaps

- The `after-change` hook runs once per key, without the changed range. [#6](https://github.com/apisandipas/imp/issues/6)
