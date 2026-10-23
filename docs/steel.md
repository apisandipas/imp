---
summary: Steel Scheme's gotchas, found while writing imp's runtime. Read before writing Scheme here.
anchors: [runtime/**, packages/**]
---
# Steel gotchas

Found so far while writing imp in Steel ([[0002-steel-scheme-as-the-extension-language]]).

## Redefinition (the big one)

Re-`define`-ing an existing global makes a new binding that code compiled earlier never sees; `set!` changes the binding everyone uses. Within one compilation unit (one `run`, one file), a call to a function never `set!` in that unit is compiled as a direct call that later `set!`s can't reach. Hence the `(set! name name)` markers the server appends to runtime files, and the `define`-to-`set!` rewrite in `imp-eval-string`. A function passed as a value at load time (`(word-motion next-word-start ...)`) is still captured: call it by name inside a lambda where redefinition matters.

- A runtime file can't call a function first defined in a later file (each file is its own unit), and `eval` of a form that references a global not yet defined fails; user code gets placeholders for those.
- Defining a name the prelude already has (`take`, `log`) fails once it is `set!` ("cannot mutate module-required identifier"). Check new runtime names against the prelude; `crates/imp-server/examples/` is the place for scratch tools. `trim` and `char-digit?` are prelude names.

## Order

- A top-level variable must be defined before any function that references it is compiled, or you get `FreeIdentifier`. Put state at the top of the file.
- Code that runs at load time (a top-level `(define-key! ...)` call) must come after the definitions it calls; function bodies may refer forward.
- `define-syntax` inside `(begin ...)` isn't visible to the later forms in it; macros are evaluated first.

## Values

- Hash maps are immutable: `(hash-insert h k v)` returns a new map, so keep it in a top-level variable and `set!` it (see `*keymaps*`).
- A `cond` clause with only a test returns void, not the test's value. Use `[(test) => (lambda (x) x)]`.
- Local names shadow builtins silently: a `let` binding called `range` broke a later `(range a b)` in the same scope.
- `void` is a value, not a function: `(void)` is an error.
- Symbols from Rust (JSON `null` is `'null`) aren't `eq?` to quoted ones; compare with `equal?`.

## Errors

- No `raise`: re-raise a caught error with `(raise-error e)`. Catch with `(with-handler (lambda (e) ...) expr)`; `(error-object-message e)` has a leading space (see `error-message` in `vim.scm`).

## Builtins

- Missing: `char-alphabetic?`, `char-numeric?`, `string-split`, `string-trim`, `char->string`. Use `char-word?` from Rust or `char->integer` ranges; `string` and `list->string` exist.
- Present and useful: `char-whitespace?`, `starts-with?`, `ends-with?`, `string-ref`, `substring`, `string->number` and `number->string` (with radix), named `let`, `case`, `syntax-rules`, `filter`, `sort`, `string-join`, `split-whitespace`, `string-contains?`, `string-upcase`, `eval`, `read`, `open-input-string`, `range`, `list-ref`, `last`, `hash-keys->list`.
- `Engine::new()` loads Steel's prelude: about 0.3 s per server.
