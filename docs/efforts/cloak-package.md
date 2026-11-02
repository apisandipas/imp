---
type: Effort
status: active
specs: ["[[spec/cloak]]"]
issue: https://github.com/apisandipas/imp/issues/152
frozen:
  docs/specs/cloak.md: 518f8370cdeb
---
# Cloak package

## Approach

Two small core pieces the package can't do without ([[decision/0011-non-essential-features-are-opt-in-packages]]), then the package in Scheme only. The mask is a sibling of the buffer layer's conceal pattern: a layer gets an optional mask (a pattern, a char and whether the cursor's line is left plain), and `render.rs` draws each masked char as the mask char repeated over the cells it takes, so the layout (cursor, wrap, clicks) is the plain line's and nothing else in the renderer moves. Being in the frame, it covers both clients and every daemon client. The completion leak is closed by a general local option, `completion-words`, that the words sources honour, rather than by the package reaching into completion. The package is a minor mode turned on from `buffer-open` and `buffer-renamed` by file-name globs, as olivetti and git-gutter turn theirs on; `cloak-reveal-line` leaves the line plain until a `post-command` hook sees the cursor leave it.

## Tasks

- [x] Core mask: `buffer-mask-pattern!` on buffer layers, drawn one mask char per cell in `render.rs`, plain on the cursor's line when asked; with render tests (wide chars, tabs, wrap, cursor position, reveal, "" stops).
- [ ] Core `completion-words` local option: the words source and the search prompt's word completion skip buffers that turn it off; with completion tests and the completion-at-point spec and page.
- [ ] The cloak package: `cloak-mode`, `SPC t c`, `cloak-file-patterns` globs on open and rename, `cloak-pattern`, `cloak-mask-char`, `cloak-reveal-cursor-line`, `cloak-reveal-line`, option changes applied at once, `completion-words` off while on; key-driven tests (masked frame, saving and yanking real text, peek, completion); the reference page, `packages/CONTEXT.md`, `PACKAGES` and the README's package list.
