---
type: Page
spec: "[[spec/live-scheme-and-help]]"
frozen:
  docs/specs/live-scheme-and-help.md: 2bdca45a37b7
---
# Live Scheme and help

imp is written in Scheme, and you can change it while it runs. Evaluate code, and the editor uses it at once. Ask the editor about any key, function or option, and it shows you the source.

## Evaluating code

Type `:eval` and an expression to run it now. The result shows on the message line.

```
:eval (+ 1 2)
```

| Key | What it does |
|---|---|
| `SPC e e` | Evaluate the form at the cursor |
| `SPC e d` | Evaluate the top-level form around the cursor |
| `SPC e r` | Evaluate the selection |
| `SPC e b` | Evaluate the whole buffer |
| `SPC e x` | Ask for an expression and evaluate it |

In [Emacs state](ref-emacs-state.md), `M-:` asks for an expression too. `:source FILE` loads a Scheme file, and `:source` alone loads the current one.

A `define` of a name that already exists replaces it everywhere, for every caller. Evaluating a definition shows the name it defines. Code with no value, such as a call made for its effect, shows nothing, so any message it showed stays.

`:messages` (or `SPC h m`) shows the last 200 messages. The keys you were typing aren't kept there.

## The REPL

`:repl` or `SPC e i` opens a `*scheme*` buffer. Type an expression after the prompt and press `<ret>` at the end. The result prints below, then a new prompt.

| Key | What it does |
|---|---|
| `M-p` / `M-n` | Replace the input with the previous or next one |
| `<up>` / `<down>` | The same, in insert state on the last prompt's line |
| `<ret>` | Evaluate the input |

As on the command line, history only steps through inputs that start with what you'd typed. Stepping past the newest brings your text back. Elsewhere in the buffer, `<up>` and `<down>` move between lines as usual.

Each input is kept whole, even across several lines, and a repeated input replaces its earlier copy. The newest 200 are saved, so history lasts across sessions. There's no searching it (`M-r` in Emacs), and no history per project.

## Asking for help

| Key | What it does |
|---|---|
| `SPC h k` | Describe a key: press it to see what it runs, with its documentation |
| `SPC h f` | Describe a function |
| `SPC h o` | Describe an option |
| `SPC h c` | Describe a command |
| `SPC h a` | List definitions whose name contains some text |
| `SPC h d` | Open the source of a definition |

`:help NAME` describes a function, option or ex command. `:help` alone lists the help commands. `:describe-key`, `:describe-function`, `:apropos` and `:find-definition` do the same as the keys.

In a Scheme buffer, press `K` on a name for its help and `gd` to go to its definition. In other files, `K` needs a language server, and says so when there isn't one.

## Documenting your code

Help reads documentation straight from the source. Put a string first in a function's body, as in Emacs:

```scheme
(define (greet name)
  "Say hello to `name`."
  (message (string-append "hello " name)))
```

For a command, the string goes first in its lambda.

## Commands you can redefine

A key bound to a command's name looks the command up each time you press it. Redefine the command, and every key bound to it runs the new version.

```scheme
(define-command! 'hello
  (lambda (count) "Say hello." (message "hello")))
(define-key! 'normal "gh" 'hello)
```

## Hooks and advice

A hook runs your code when something happens. Add to it with `add-hook!`, and take it off with `remove-hook!`, passing the same procedure:

```scheme
(add-hook! 'after-save (lambda () (message "saved")))
```

`run-hooks` runs a hook by hand.

Advice changes what a function does without rewriting it. `advice-add!` takes the function's name, then `'before`, `'after` or `'around`, then your procedure. `'before` and `'after` get the same arguments. `'around` gets the original function first, and decides whether to call it.

```scheme
(advice-add! 'save-buffer 'before (lambda (count) (message "saving")))
```

`advice-remove!` takes it off again. Every caller sees advice.

## Watching edits

`(buffer-version)` gives the current buffer's version. Later, `(buffer-changes-since version)` lists the edits made since, oldest first. Each is a list:

```scheme
(start old-end new-end text start-line start-col old-end-line old-end-col)
```

The offsets count characters, `text` is what was inserted, and the lines and columns say where the edit started and ended before it was made. The answer is `#f` when the edits aren't known: across an undo, a redo or a reload, or more than 1000 edits back.

In an `after-change` hook, `(after-change-range)` gives everything the last key changed as one `(start old-end new-end)`, like Emacs's `after-change-functions`. It's `#f` when that isn't known. The hook itself takes no arguments.
