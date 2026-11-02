---
type: Page
spec: "[[spec/org-babel]]"
frozen:
  docs/specs/org-babel.md: 0f2ad79678a0
---
# Org babel

Org babel runs the code in an [Org](ref-org.md) source block and writes what it gives back under the block. It works as Org Babel does in Emacs.

## Not yet in imp

- Running the whole buffer starts every shell, Python or other block at once rather than waiting for each, so one block can't rely on what an earlier one did. Scheme blocks do run in order.
- A Scheme block that never finishes freezes the editor.

## Turning it on

Org babel is an opt-in package. Load it in your `init.scm`:

```scheme
(use-package! 'org-babel)
```

## Running a block

Put the cursor anywhere in a source block, including its `#+begin_src` and `#+end_src` lines, and press `C-c C-c`. imp asks `Run this python block? (y or n)`; press `y`. The results go under the block:

```org
#+begin_src python
print(6 * 7)
#+end_src

#+RESULTS:
: 42
```

Run it again and the old results are replaced. Results longer than 10 lines go between `#+begin_example` and `#+end_example` instead of each starting with a colon.

| Key | What it does |
|---|---|
| `C-c C-c` | Run the source block at the cursor |
| `C-c C-v C-b` | Run every source block in the buffer, top to bottom, after one question |
| `C-c C-v k` | Remove the block's results |

The keys work in normal and insert state. Each change to the results is one undo step. To stop being asked first, set `org-babel-confirm` to `#f`.

## Scheme blocks

A `scheme` or `steel` block runs inside imp itself, as an `emacs-lisp` block runs inside Emacs. What it defines stays defined, for later blocks and for the editor. Its result is the value of its last form:

```org
#+begin_src scheme
(define x 6)
(* x 7)
#+end_src

#+RESULTS:
: 42
```

An error shows on the message line and leaves the results alone.

## Other languages

Other languages run in the background, so you can keep editing. The code goes to an interpreter's standard input, and the result is everything it printed, errors included. The message line says when the block finishes, and its exit code if it failed.

These work out of the box: `sh`, `shell`, `bash`, `zsh`, `fish`, `python`, `python3`, `js`, `javascript`, `node`, `ruby`, `perl`, `lua` and `R`. Add a language to `org-babel-interpreters`, as a language name and the shell command that runs it:

```scheme
(set-option! 'org-babel-interpreters
  (cons '("ts" "deno run -") (option 'org-babel-interpreters)))
```

## Header arguments

Two of Org's header arguments work, written after the language:

| Header argument | What it does |
|---|---|
| `:dir DIR` | Run the code in directory `DIR` |
| `:results silent` | Show the result on the message line instead of in the buffer |

```org
#+begin_src sh :dir ~/src :results silent
ls | wc -l
#+end_src
```

Others, such as `:var`, `:session` and `:tangle`, are not supported.

## Options

| Option | Default | What it does |
|---|---|---|
| `org-babel-confirm` | `#t` | Ask before running a block |
| `org-babel-interpreters` | the languages above | `(LANGUAGE COMMAND)` pairs: the command that runs that language's code from its standard input |
| `org-babel-example-lines` | `10` | Results longer than this many lines go in an example block |
