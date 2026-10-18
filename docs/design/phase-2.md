# Phase 2 design: the Emacs half

Written at the start of the phase; the Outcome section at the end records
what changed. Roadmap items are in `docs/HANDOFF.md` §6.

## Order, and one item pulled forward

1. **Multiple buffers (3.1), pulled forward.** Per-buffer major modes (2.6),
   find-file through completion (2.8) and jump-to-source (2.2) all need more
   than one buffer; building them for a single buffer first would mean doing
   them twice. Windows and splits (3.2) stay in Phase 3.
2. Live evaluation (2.1), including the redefinition fix below.
3. Self-documentation (2.2).
4. Hooks and advice (2.3).
5. Completion framework (2.8), moved up because the leader key's main
   bindings (find file, M-x, switch buffer, describe-function) use it.
6. Leader key and which-key (2.4).
7. Major and minor modes (2.6).
8. Emacs ("holy") bindings (2.5).
9. Packages (2.7).

## Live redefinition: `define` vs `set!` in Steel

Probing Steel 0.8.3 showed:

- Re-`define`-ing an existing global creates a *new* binding. Code compiled
  earlier keeps calling the old one. So a user's `(define (foo) ...)` in
  `init.scm` only shadows the runtime's `foo`; the runtime never sees it.
- `set!` on an existing global updates the binding everyone uses.
- `eval` of quoted forms works, including `define-syntax`.

So imp evaluates user code through its own loader (`imp-eval-form` in
`core.scm`): a top-level `(define (name ...) ...)` or `(define name ...)`
whose name is already bound becomes `(set! name ...)`. New names are defined
as usual. `init.scm`, `:eval`, eval-region and packages all go through it.
This is what makes "redefine anything while it runs" true.

Values captured at load time (a closure built by `(half-page-scroll! 1)` and
stored in a keymap) don't change when the function that built them is
redefined. Emacs behaves the same way; named commands (below) avoid it for
key bindings.

## Multiple buffers

Rust keeps the current buffer in `Editor.buffer` (so every existing
primitive keeps working) and parks the others, with their cursor and scroll,
in a map by id. Switching swaps them. Primitives: `buffer-list`,
`current-buffer`, `buffer-open!` (or the existing buffer for that file),
`buffer-new!`, `switch-to-buffer!`, `buffer-kill!`, `buffer-info` (name,
path, modified). Marks stay per buffer; the jump list records the buffer
with each entry. Scheme keeps buffer-local state in a table keyed by id.

Ex: `:e FILE`, `:e!`, `:enew`, `:ls`, `:b N|name`, `:bn`, `:bp`, `:bd[!]`,
`C-^`, and `:wa`/`:qa`/`:wqa`/`:xa` over all buffers.

## Commands, documentation and source

- **Named commands**: `(define-command! name proc)` registers `proc` under a
  symbol; keymaps can bind the symbol, looked up when the key is pressed, so
  redefining a command changes every key bound to it. M-x lists commands.
- **Docstrings are the comment block above a definition**, which is how the
  runtime is already written. The runtime sources (and `init.scm`) are kept
  by the server; `describe-function` finds `(define (name` in them and shows
  the comment, the signature and `file:line`. `describe-key` works out what
  a key does (motion, operator, text object, keymap command, leader binding)
  and finds the `define-motion!`/`define-key!`/... form for it the same way.
  `find-definition` opens the source at that line (runtime files are opened
  from `IMP_RUNTIME` when set, else as read-only scratch copies).

## Hooks and advice

- `(add-hook! 'name proc)`, `(remove-hook! 'name proc)`, `(run-hooks 'name
  args ...)`. Built-in hooks: `after-change`, `before-save`, `after-save`,
  `post-command`, `insert-enter`, `insert-leave`, `mode-change`,
  `buffer-enter`, `buffer-open`, `option-change`.
- `(advice-add! 'name 'before|'after|'around proc)` and `advice-remove!`:
  the original is kept, and the name is `set!` to a wrapper that runs the
  advice. Because of the `set!` semantics above, every caller sees it.

## Completion

`(completing-read prompt candidates on-select)` opens the prompt with a
popup of matches. Matching is orderless: the query is split on spaces and
every part must match, as a substring or, failing that, as a fuzzy
subsequence; results are ranked by a score. A Rust primitive does the
filtering and scoring (`fuzzy-filter`), since candidate lists (files in a
project) can be large. `C-n C-p <up> <down> <tab> <s-tab>` move, `<ret>`
selects. Used by M-x, find-file, switch-buffer, describe-*.

## Leader key and which-key

Space is the leader in normal and visual mode. `(define-leader! keys command
description)` and `(define-leader-group! keys name)` fill a tree; typing the
leader shows a which-key popup of the next keys and their descriptions,
updated as keys are typed. Default groups: `b` buffers, `e` eval, `f`
files, `h` help, `s` search, `t` toggles, `w` windows (later), `q` quit;
`SPC :` and `SPC SPC` run M-x.

## Major and minor modes

`(define-major-mode! name parent extensions setup)` and
`(define-minor-mode! name keymap setup teardown)`. A buffer has one major
mode, picked by file extension when it opens, and any number of minor
modes. Key lookup: minor modes' keymaps, then the major mode's (and its
parents'), then the global state keymap. Options get buffer-local values
(`set-local-option!`), so a mode can set `shiftwidth`. Modes also give the
comment string, used by a new `gc` comment operator.

## Emacs bindings

An `emacs` state beside normal/insert/visual: keys insert text, and the
usual Emacs keys edit (`C-f C-b C-n C-p C-a C-e M-f M-b C-d M-d C-k C-y M-y
C-w M-w C-SPC C-g C-s C-r C-/ C-x C-s C-x C-c M-x M-< M->`...). Kills go to
the unnamed register and a kill ring. `C-z` toggles between Vim and Emacs
state as in Evil; `:set editing-style=emacs` (in init.scm) starts in it.

## Packages

`~/.config/imp/packages/NAME/` holds a package; its `NAME.scm` (or
`init.scm`) is loaded through `imp-eval-form`. `(use-package! 'name
'(git "URL") '(rev "SHA") '(config ,thunk))`-style declarations in
`init.scm` clone missing packages with `git` (pinned to a commit when
given) and load them. `:packages` lists them.

## Outcome

Built in the planned order, with these findings and changes:

- **Redefinition needed more than define→set!.** Steel also compiles a call
  to a function defined in the same unit, and never `set!` there, as a direct
  call. The server now appends `(set! name name)` for every top-level runtime
  definition (no measurable cost), and user code is evaluated as one unit
  with the same markers. One-unit evaluation was needed anyway: form-by-form
  evaluation broke forward references inside a file. Macros are evaluated
  first, because a `define-syntax` inside `(begin ...)` isn't visible to the
  forms after it.
- **Names defined later.** `init.scm` is compiled before packages load, so a
  `use-package!` config naming a package function failed to compile. Missing
  globals in user code now get a placeholder that the real definition
  replaces.
- **Runtime files extend each other through variables, tables and hooks**
  (`*key-interceptor*`, `*local-keymaps*`, `*extra-states*`,
  `*cmdline-key-handler*`, the `startup` hook), never forward calls.
- **Line numbers, cursorline and horizontal scrolling** were added: the toggle
  group needed something to toggle, and long lines hid the cursor.
- **Insert mode checks mode keymaps first**, so a major mode can rebind
  `<ret>` (the REPL does).
- **Server::eval** goes through the same evaluator as `:eval`, so tests
  exercise the real path.
- Deferred: REPL history, which-key for Vim prefixes and on a delay (no
  timers yet), ranges for `after-change`.
