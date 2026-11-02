---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/158
summary: "The org-babel package: C-c C-c in an Org source block runs its code, Scheme inside imp and other languages through an interpreter, and puts the results under the block."
anchors: [packages/org-babel/org-babel.scm, crates/imp-server/tests/org_babel.rs]
---
# Org babel

A bundled package, after Emacs's [Org Babel](https://orgmode.org/manual/Working-with-Source-Code.html), that runs the code in an Org buffer's source blocks ([[spec/org]]) and writes what it gives back under the block as a `#+RESULTS:` block. It is off until loaded ([[0011-non-essential-features-are-opt-in-packages]]), with `(use-package! 'org-babel)`.

## Behaviour

- A source block runs from its `#+begin_src LANGUAGE` line to its `#+end_src` line, matched without regard to case or indentation. The words after the language are header arguments. The code is the lines between, less the indentation of the `#+begin_src` line.
- `C-c C-c` in normal or insert state, on any line of a source block including the two delimiter lines, runs that block. Outside one it says `not in a source block`.
- With `org-babel-confirm` on (the default, as in Org), it first asks `Run this LANGUAGE block? (y or n)`; only `y` runs it.
- **Scheme.** A `scheme` or `steel` block runs inside imp, as `emacs-lisp` blocks run inside Emacs, so what it defines stays defined for later blocks and for the editor. Its result is the value of its last form: a string as it is, an empty result for no value, any other value as Scheme prints it. It runs at once, and the editor waits for it. An error says `error: MESSAGE` on the message line and leaves the results as they were.
- **Other languages.** A block in a language listed in `org-babel-interpreters` runs in the background through that shell command, its code on the command's standard input, and its result is everything it printed, to standard output and standard error together. The message line says `running the LANGUAGE block...` and then `LANGUAGE block finished`, adding `with exit code N` when it failed; the results go in when it finishes, and editing meanwhile is fine. A language not listed says `no interpreter for LANGUAGE; add it to org-babel-interpreters`.
- `:dir DIR` runs a background block in that directory (`~` expanded), not the editor's.
- **Results.** They go under the block's `#+end_src` line after one blank line: `#+RESULTS:`, then each line of the result after `: ` (an empty line as a bare `:`), or, when the result has more than `org-babel-example-lines` lines (default 10), the lines as they are between `#+begin_example` and `#+end_example`. Every line is indented as the `#+begin_src` line is. Running the block again replaces its old results rather than adding more. Results whose block was deleted while it ran are dropped.
- `:results silent` shows the result on the message line instead, and leaves the buffer alone.
- `C-c C-v k` removes the results under the block at the cursor, with the blank line before them, or says `no results here`.
- `C-c C-v C-b` runs every source block in the buffer, starting them top to bottom, after one question for all of them (`Run all N blocks?`) when `org-babel-confirm` is on. Each block's results go under it as with `C-c C-c`.
- Each insertion or removal of results is one undo step.

## Keys and options

| Key, command or option | Default | What it does |
|---|---|---|
| `C-c C-c`, `M-x org-babel-execute` | | Run the source block at the cursor |
| `C-c C-v C-b`, `M-x org-babel-execute-buffer` | | Run every source block in the buffer |
| `C-c C-v k`, `M-x org-babel-remove-result` | | Remove the block's results |
| `org-babel-confirm` | `#t` | Ask before running |
| `org-babel-interpreters` | sh, shell, bash, zsh, fish, python, python3, js, javascript, node, ruby, perl, lua, R | `(LANGUAGE COMMAND)` pairs: the shell command that runs code given on its standard input |
| `org-babel-example-lines` | `10` | Results longer than this many lines go in an example block |

## Out of scope

- Org Babel's other header arguments: `:var`, `:session`, `:exports`, `:tangle`, `:results` values other than `silent`, and the rest.
- Tangling blocks out to files, and running inline `src_LANG{...}` code.
- Results as Org tables or lists, or naming blocks and their results.
- Running code in any Org buffer without being asked, as on opening it.

## Known gaps

- `C-c C-v C-b` starts the background blocks one after another but does not wait for each to finish, so they run at the same time and a later block cannot rely on what an earlier one did. Scheme blocks, which run at once, do run in order.
- A Scheme block that loops forever hangs the editor.
