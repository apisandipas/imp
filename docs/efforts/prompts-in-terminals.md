---
type: Effort
status: active
specs: ["[[spec/terminals]]"]
issue: https://github.com/apisandipas/imp/issues/88
frozen:
  docs/specs/terminals.md: 2777f2c01ee9
---
# Prompts in terminals

## Approach

`term.rs`'s `Reports` gets the OSC 133 marks from `unhandled_osc`, each at an absolute line: the lines dropped from the front of the history so far, plus the history's length, plus the lines scrolled into vt100's scrollback since the last render, plus the cursor's row. `term-prompts` gives them back as buffer lines, (prompt-line output-line end-status) per command, leaving out those scrolled away. `term.scm` builds the `]]`/`[[` motions, the `io`/`ao` text objects and the signs from that list.

## Tasks

- [x] The marks: `term-prompts` from OSC 133 `A`, `C` and `D;N`, kept at the right lines as history scrolls and dropped when it scrolls away; a Rust test feeding sequences to a parser. Then `]]` and `[[` (counts, operators, nowhere elsewhere), `io` and `ao`, and the `›`/`✗` signs. Tests with a stand-in that prints the marks, and the reference page with the bash and zsh lines.
