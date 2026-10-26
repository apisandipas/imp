---
type: Page
spec: "[[spec/wasm-plugins]]"
frozen:
  docs/specs/wasm-plugins.md: b62f9140ac75
---
# WASM plugins

A WASM plugin is a WebAssembly module that turns text into other text. It runs sealed off from your system, so it suits heavy work or code you don't fully trust. Scheme is still the main way to extend imp; plugins are a prototype, only in an imp built with `--features wasm`.

## What a plugin can do

A plugin's functions each take a string and give back a string. They can't touch files, the network or the clock. Their one way out is a log, which `:wasm-log` shows.

Each call has a budget of work, and each plugin a memory limit. A plugin that runs away stops with an error instead of hanging the editor.

## Using a plugin

Load it in `init.scm` under a name, then hang its functions on keys or commands:

```scheme
(load-wasm-plugin! 'case "~/.config/imp/plugins/case.wasm")
(define-operator! "gs" (wasm-operator 'case "snake"))
(define-wasm-filter! 'snake-buffer 'case "snake")
```

`wasm-operator` makes a Vim operator. Here `gsiw` turns the word under the cursor into snake case, and `gs` does the same to a visual selection.

`define-wasm-filter!` makes a command that runs a function over the whole buffer, here `M-x snake-buffer`. The change is one undo step.

In an imp built without the feature, these still exist, but fail with "imp was built without the wasm feature".

## Commands

| Command | What it does |
|---|---|
| `:wasm` | List the loaded plugins and their functions |
| `:[range]wasm PLUGIN FUNCTION` | Run a function over the lines in the range, or the whole buffer |
| `:wasm-log` | Show what plugins have logged |

## Writing a plugin

imp's source has an example in `examples/wasm-plugin`: a Rust plugin whose functions `snake`, `camel` and `kebab` change the case of identifiers. Build it with:

```sh
cargo build --release --target wasm32-unknown-unknown
```

A plugin is a plain WebAssembly module, not a component, and without WASI. It exports its `memory` and a function `imp_alloc(len)`, which imp calls to get room for the input. Each function takes the address and length of a UTF-8 string, and returns its result's address shifted left 32 bits, joined with its length. The one thing it can import is `imp.log`.

