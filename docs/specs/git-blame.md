---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/50
summary: "The git-blame package: the cursor's line's last commit, after the line, as GitLens shows it."
anchors: [packages/git-blame/git-blame.scm, crates/imp-server/tests/git_blame.rs]
---
# Git blame

A bundled package ([[0011-non-essential-features-are-opt-in-packages]]): `(use-package! 'git-blame)`.

## Behaviour

- Loading it turns on `git-blame-mode` in every buffer visiting a file in a git repository, as it opens.
- In `git-blame-mode`, once the cursor has rested on a line for `git-blame-delay` milliseconds (500) in normal state, the commit that last changed the line shows after it, as end-of-line text ([[buffers-and-windows]]) in the `git-blame` face: `Bryan Paronto, 3 days ago • Add x` (author, git's relative date, subject). A line not committed yet says `Not committed yet`.
- It blames the buffer's text as it is (`git blame --contents -`), so unsaved edits don't put it on the wrong line, and runs git in the background.
- Moving the cursor off the line, changing the buffer or entering insert state hides it, until the cursor rests again.
- `SPC g b` and `:GitBlame` turn `git-blame-mode` off and on in the current buffer.
- Outside a repository, or for a file git doesn't track, nothing shows.

## Keys and options

`SPC g b`, `:GitBlame`, `git-blame-delay`, the `git-blame` face.

## Out of scope

- Blame on every line at once, or a blame buffer (`:Git blame` shows git's own output).
- A format option, and a popup with the whole commit.
