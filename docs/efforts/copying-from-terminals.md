---
type: Effort
status: active
specs: ["[[spec/terminals]]"]
issue: https://github.com/apisandipas/imp/issues/89
frozen:
  docs/specs/terminals.md: 65e6217721c1
---
# Copying from terminals

## Approach

vt100 hands OSC 52 to `Callbacks::copy_to_clipboard` with the selection and the base64 text, and reads to `paste_from_clipboard`, which is left unanswered. `term.rs`'s `Reports` decodes the text (a small decoder: the `base64` crate is only behind the `crdt` feature) and queues it; `term.scm` takes the queue on each redraw and puts each copy in `"+` or `"*` with `register-set!`, which reaches the clipboard tools.

## Tasks

- [ ] OSC 52 copies: decoded and queued in `term.rs` (`term-take-copies!`), put in `"+` (or `"*` for `p`) and the unnamed register with a message; reads unanswered; `terminal-clipboard` off ignores them. A Rust test of the decoding and selector, tests with a stand-in that sends OSC 52, and the reference page.
