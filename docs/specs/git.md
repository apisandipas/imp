---
status: accepted
issue: https://github.com/apisandipas/imp/issues/2
summary: "A Magit-style status buffer: staging, commits, log, diffs, branches, stashes, and remotes."
anchors: [runtime/git.scm, crates/imp-server/tests/git.rs]
---
# Git

## Behaviour

- `SPC g g` or `M-x git-status` opens the status of the current file's repository, down the right: the head (branch and subject), the upstream (ahead and behind), Untracked, Unstaged and Staged files, stashes and the `git-recent-commits` latest commits. It refreshes when you come back to it, and on `gr`.
- Two key lines are pinned as a footer at the bottom of the status window, as Magit's transients show at the bottom. They sit on a band in the status line's background, the `git.footer` face, with a blank line of it above and below, so they read as part of the window rather than the buffer. The keys are in five columns, a related pair in each: `s stage` over `<tab> diff`, `u unstage` over `x discard`, `c commit` over `b branch`, `F pull` over `P push`, and `l log` over `? keys`. In each column the keys are right-aligned and the labels left-aligned, so both lines line up; each key is in the `git.footer.key` face. The lines are 49 columns wide, so they fit the status window beside a file in a 100-column terminal; a narrower window cuts them at its edge. `(set-option! 'git-status-hints #f)` leaves them out.
- `<tab>` on a file shows or hides its diff, hunk by hunk.
- `s` and `u` stage and unstage the file or hunk at the cursor; `S` and `U` everything; `x` discards after asking. A hunk is staged by feeding its patch to `git apply --cached`.
- Menus, as Magit's transients: `c` commit (`c` commit, `a` amend, `e` extend), `b` branch (checkout, create), `d` diff (unstaged, staged), `z` stash (stash, pop, apply), `f` fetch, `F` pull (and `--rebase`), `P` push (and set upstream). `l` shows the log; `<ret>` visits the thing at the cursor (a file at its line, a commit).
- Commit messages are edited in a buffer; `ZZ`, `C-c C-c` or `SPC m c` commits, `ZQ`, `C-c C-k` or `SPC m k` cancels.
- Fetch, pull and push run in the background; `$` shows git's output.
- `?` opens a menu, as the other prefixes do and Magit's `?` does: every status key with its label, and the key pressed runs, acting on the item at the cursor; a menu key (`c`, `P`) opens its menu. The key lines, `?` and which-key read their labels from the same table of (key label action) the keys are bound from, so a key added there shows in all three.
- `M-x git` asks for git's arguments, runs git with them and shows its output; with none it opens the status. `:git ARGS` gives them at once ([[commands]]). `SPC g l` shows the log.
- Status is parsed from `git status --porcelain=v2 --branch -z`; parsed commands run synchronously (they are fast), network ones as jobs. Unusual file names are unquoted.

## Keys and options

`git-recent-commits`, `git-status-hints` (#t).

## Known gaps

- Key lines in the log, diff and commit buffers.
- No staging of selected lines, rebase, merge or blame, and no refresh on save.
