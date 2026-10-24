---
type: Effort
status: planned
specs: ["[[spec/git-blame]]", "[[spec/buffers-and-windows]]"]
issue: https://github.com/apisandipas/imp/issues/50
frozen:
  docs/specs/git-blame.md: 5d440041ec6f
  docs/specs/buffers-and-windows.md: 35e2b8900dbb
---
# Git blame package

The cursor's line's last commit after the line, from a bundled `git-blame` package, on end-of-line text the renderer learns to draw.

## Approach

Core gets one primitive, the one the package can't do without ([[0011-non-essential-features-are-opt-in-packages]], [[0005-rust-owns-data-and-speed-scheme-owns-behavior]]): `set-line-end-text!` puts text in a face after a line of the current buffer, or removes it, and the renderer draws it past the line's end. Everything else is `packages/git-blame/git-blame.scm`, using `git.scm`'s helpers. A `post-command` hook in `git-blame-mode` buffers hides what is shown and, in normal state, starts a `git-blame-delay` timer; when it fires on the same line and buffer version, a background job runs `git blame --porcelain -L N,N --contents -` with the buffer's text on stdin, and its output, if the cursor is still there, becomes the line's end text. The relative age is worked out in Scheme from the commit's author time, as git words it.

## Tasks

- [ ] `set-line-end-text!` (line, text, face; text #f removes it) for the current buffer; the renderer draws it two cells past the line's end, cut at the window's edge, after the last row of a wrapped line, not on a closed fold. Tests in `tests/render.rs`.
- [ ] `packages/git-blame/git-blame.scm`, listed in `PACKAGES` and `packages/CONTEXT.md`: `git-blame-mode`, turned on as a file in a repository opens; `SPC g b` and `:GitBlame` toggle it. Tests in `tests/git_blame.rs`.
- [ ] After the cursor rests `git-blame-delay` ms in normal state, the line's blame shows in the `git-blame` face: `Author, N days ago • subject`, or `Not committed yet`; blamed with `--contents -` in the background; hidden on moving, a change or insert state; nothing for an untracked file or outside a repository. Tests in `tests/git_blame.rs` on a temporary repository.
- [ ] Checked by hand by the owner.
