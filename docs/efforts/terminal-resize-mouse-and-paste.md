---
type: Effort
status: active
specs: ["[[spec/terminals]]"]
issue: https://github.com/apisandipas/imp/issues/16
frozen:
  docs/specs/terminals.md: c44527e5e969
---
# Terminal resize, mouse and paste

Size every terminal to its windows, pass the mouse to programs that ask, and paste whole.

## Approach

A new primitive gives any window's text size; `term.scm` sizes each terminal to the smallest window showing it on output and in a `post-command` hook (`term-resize!` does nothing when the size is unchanged). For the mouse, primitives report what the program asked for (vt100's mouse protocol mode and encoding), where its screen starts in the buffer, and which cell of a window was hit; `mouse.scm` (loaded before `term.scm`) asks a handler variable that `term.scm` sets before doing its own thing. For paste, `ClientMsg::Paste` carries the text from the terminal client, which enables bracketed paste; the server calls `imp-handle-paste`, which runs the hooks a key does and puts the text where the state wants it, with a handler variable `term.scm` sets for the TERMINAL state.

Decisions made while the owner was away (issue #16 had no answers yet): the smallest window wins, as in Neovim; mouse forwarding only in the TERMINAL state and the current window, so a click elsewhere still focuses; paste in normal and visual state inserts at the cursor (as Neovim's paste does) rather than putting a register; the window client doesn't get paste yet.

## Tasks

- [x] `window-text-size` and `term-size` primitives; every terminal sized to the smallest window showing it, on output and after each command. Tested in `term.rs` with two windows.
- [ ] Mouse: `term-mouse-mode`, `term-mouse-encoding`, `term-screen-top` and `window-cell` primitives, and forwarding in SGR and classic encodings by mode. Tested in `term.rs` with a program that turns on mouse reporting and prints what it reads.
- [ ] Paste: `ClientMsg::Paste`, the terminal client's bracketed paste, `imp-handle-paste` for insert, normal, visual, command line and TERMINAL state. Tested in `term.rs` and a new `paste.rs`.
- [ ] Docs: `crates/imp-core/CONTEXT.md` protocol section lists `Paste`; README mentions the terminal's mouse and paste if it describes terminals.
