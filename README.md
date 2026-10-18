# imp

An editor as flexible as Emacs, built in 2026: a small Rust core, the editor
itself written in Scheme ([Steel](https://github.com/mattwparas/steel)), and
Vim editing by default.

## Running it

```sh
nix develop          # or any recent stable Rust toolchain
cargo run -- FILE
cargo test
```

Inside `nix develop`, `IMP_RUNTIME` points at `runtime/`, so edits to the
Scheme files take effect when imp restarts, with no rebuild. Without it, the
copies embedded in the binary are used.

## Configuration

`~/.config/imp/init.scm` (or `$XDG_CONFIG_HOME/imp/init.scm`) loads after the
runtime and can redefine anything in it:

```scheme
;; A new key in normal mode.
(define-key! 'normal "U" (lambda (count) (redo!)))

;; A new motion. It works with d, c, y, counts and `.` with no further code.
(define-motion! "Q" 'exclusive (lambda (from n) (buffer-length)))
```

An error in `init.scm` shows on the status line; the editor still starts.

## Layout

```
crates/
  imp-core/    the text buffer and the client/server messages
  imp-server/  event loop, Steel embedding, the Rust functions Scheme can call
  imp/         the terminal client (package imp-editor, binary imp)
runtime/
  core.scm     keymaps and buffer helpers
  vim.scm      modes, motions, operators, dot-repeat, :commands
```

## Design rules

- **Rust owns data and speed; Scheme owns behavior.** `imp-server/src/api.rs`
  is the whole boundary: read the buffer, change it, move the cursor, report
  state. What a key does is decided in Scheme.
- **Clients are dumb.** They send keys and draw frames (a grid of rows).
  Modes and keymaps live in the server. The client runs the server on a
  thread for now; the channels between them are where a socket goes.
- **One thread owns the Steel VM** and all editor state. Future background
  work (LSP, file watching) posts messages to it.
- **Dot-repeat records commands, not keystrokes.** The last change is a
  closure, so `.` reruns the command itself at the new position.

## What works

Normal: `h j k l` and arrow keys, `w b e 0 ^ $ gg G`, counts (`3w`, `2d3w`),
operators `d c y` with any motion and doubled (`dd cc yy`), `x X D C s`,
`p P`, `u`, `C-r`, `.`.
Insert: `i a I A o O`, typing, `<ret>`, `<bs>`, `<esc>`.
Command line: `:w :q :q! :wq :x :N`.

## Not yet

Visual mode, search, registers beyond the unnamed one, text objects
(tree-sitter-backed is the plan), multiple buffers and windows, syntax
highlighting, styled cells in the frame protocol, the socket transport.
