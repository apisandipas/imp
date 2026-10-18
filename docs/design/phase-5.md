# Phase 5 design: long-term architecture, as prototypes

Written at the start of the phase; the Outcome section records what
changed.

## Principle

The owner's rule for this phase: prototype behind cargo features or in
separate crates, and don't change the core design. So each item is off
in a default build (`cargo build`, `nix build`, `cargo test`) and turns on
with a feature or by building its own crate. The core stays one thread
owning the Steel VM and all editor state, with clients that draw frames.

Where a prototype needs Scheme to reach it, the primitives are always
registered, so runtime files load the same either way. Without the
feature they fail with "imp was built without the X feature".

`tools/check.sh` also builds and tests with every feature on, and lints
the GUI crate, so the prototypes don't rot.

## WASM plugins (5.1): feature `wasm`

Wasmtime runs plugins as **core modules with a small string ABI**, not
yet the component model. Components need `wasm32-wasip2` and
`cargo-component`, which this toolchain doesn't have. Core modules build
with plain `rustc --target wasm32-unknown-unknown`, from any language,
and can be written by hand as WAT for tests. The ABI is small enough to
swap for WIT later.

- A plugin exports `memory` and `imp_alloc(len) -> ptr`.
- A function plugins offer takes `(ptr, len)` of a UTF-8 string and
  returns an i64: `ptr << 32 | len` of its UTF-8 result.
- The host offers one import, `imp.log(ptr, len)`, which writes to the
  plugin log.
- It has no WASI: no files, no network, no clock. A plugin is a pure
  function from string to string. That is the sandbox, and it makes
  plugins good for formatters, linters and transforms.
- Each call has a fuel budget, so a runaway plugin returns an error
  instead of hanging the editor. Each plugin has a memory limit.

Scheme:
- `(wasm-load PATH)` returns a plugin handle.
- `(wasm-call PLUGIN NAME INPUT)` returns a string or raises an error.
- `(wasm-exports PLUGIN)` lists what the plugin offers.

`runtime/wasm.scm` builds on these:
- `define-wasm-filter!` makes a command that runs a plugin function over
  the selection or the buffer, as one undo step.
- `:wasm-log` shows the plugin log.

Calls run on the editor thread. Fuel bounds them; moving long calls to a
thread can come later.

An example plugin in Rust lives in `examples/wasm-plugin`, outside the
workspace.

## GPU GUI client (5.2): crate `imp-gui`

A second client, just like the terminal one:
- It uses winit for the window, wgpu for drawing, and glyphon
  (cosmic-text) for text.
- It runs the server in-process, as `imp FILE` does, or attaches to a
  daemon with `imp-gui --connect`.
- It sends the same `ClientMsg`s, keys and mouse included, and draws the
  same `Frame`s: cell backgrounds as quads, text with glyphon, and the
  cursor shape the frame asks for.
- Font and size are command-line options, with the system monospace font
  by default.

The crate is a workspace member but not a default member, so the
terminal build doesn't pull in wgpu. Building it needs no system
libraries: winit and wgpu load X11, Wayland and Vulkan at run time.

The renderer is separate from the window. `imp-gui --screenshot OUT.png`
draws frames off-screen and saves a PNG. That is how it's tested here,
with no display or GPU: Mesa's lavapipe software Vulkan driver.

## CRDT buffers (5.3): feature `crdt`

The owner said to proceed carefully, so the CRDT is not hand-written. It
uses `yrs`, the Rust port of Yjs, which is widely used and tested. The
editor's buffer stays the rope; a shared buffer keeps a yrs document
beside it as a mirror.

- **Local changes:** syncing compares the buffer with the mirror (common
  prefix and suffix) and records the difference as one yrs change. That
  needs no hooks in the buffer's edit path. The core is unchanged, and
  any way of editing, Scheme or MCP, is covered.
- **Remote changes:** applying a remote update to the mirror gives a
  delta (retain, insert, delete). It is applied to the buffer as ordinary
  edits, so marks, the cursor and the syntax tree follow.

Primitives:
- `(crdt-share! BUF SITE)` starts mirroring the buffer.
- `(crdt-sync! BUF)` returns the update since the last sync, as base64,
  or #f if nothing changed.
- `(crdt-apply! BUF UPDATE)` applies a remote update.
- `(crdt-state BUF)` and `(crdt-diff BUF STATE)` bring a joining peer up
  to date.

`runtime/collab.scm` puts it on the socket support from 4.4:
- `:share` serves the current buffer on a socket.
- `:join PATH` opens a shared buffer from another editor.
- The host relays updates between peers. Syncing runs after each command
  and on a short timer.

This needs a socket-connect primitive, the client side of the existing
listeners.

Limitations, accepted for a prototype:
- Undo is still local and text-based. Undoing after a remote edit undoes
  by position, which can be wrong.
- There is no presence: other cursors aren't shown.

## Typed config (5.4): feature `kdl`

KDL rather than Nickel. It's a small, plain data format with a parser
crate, and fits "options, keys, theme" well. Nickel's typing would cost a
large dependency for a low-priority item.

- `(kdl-parse TEXT)` turns a document into lists:
  `(name (args...) ((key . value)...) (children...))`.
- `runtime/config.scm` interprets the nodes and reports unknown ones and
  bad values with their line numbers. `~/.config/imp/config.kdl` loads
  before `init.scm`, so Scheme can still override it.

```kdl
theme "gruvbox-dark"
option "number" #true
option "tabstop" 4
leader "gs" "save-buffer" "save"
key "normal" "C-s" "save-buffer"
language-server "python-mode" "pylsp" markers=".git pyproject.toml" language="python"
```

## Order

5.1, 5.2, 5.3, 5.4, each committed when `tools/check.sh` passes.

## Progress

- 5.1 WASM plugins: done.
  - `src/wasm.rs` and `runtime/wasm.scm`, with `wasm-operator` (a Vim
    operator), `define-wasm-filter!`, `:[range]wasm`, `:wasm` and
    `:wasm-log`.
  - The example Rust plugin in `examples/wasm-plugin` converts case. It
    needs `lld` to link: `nix shell nixpkgs#lld -c cargo build --release
    --target wasm32-unknown-unknown`.
  - Tests use WAT plugins, plus the example when it has been built.
  - Writing these tests found a core undo bug, fixed separately: a change
    made right after `u` or `C-r` was undone together with the change
    before it.
