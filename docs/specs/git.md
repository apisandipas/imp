---
status: accepted
summary: "A Magit-style status buffer: staging, commits, log, diffs, branches, stashes, and remotes."
anchors: [runtime/git.scm, crates/imp-server/tests/git.rs]
---
# Git

## Behaviour

- `SPC g g` or `:Git` opens the status of the current file's repository, down the right: the head (branch and subject), the upstream (ahead and behind), Untracked, Unstaged and Staged files, stashes and the `git-recent-commits` latest commits. It refreshes when you come back to it, and on `gr`.
- `<tab>` on a file shows or hides its diff, hunk by hunk.
- `s` and `u` stage and unstage the file or hunk at the cursor; `S` and `U` everything; `x` discards after asking. A hunk is staged by feeding its patch to `git apply --cached`.
- Menus, as Magit's transients: `c` commit (`c` commit, `a` amend, `e` extend), `b` branch (checkout, create), `d` diff (unstaged, staged), `z` stash (stash, pop, apply), `f` fetch, `F` pull (and `--rebase`), `P` push (and set upstream). `l` shows the log; `<ret>` visits the thing at the cursor (a file at its line, a commit).
- Commit messages are edited in a buffer; `ZZ`, `C-c C-c` or `SPC m c` commits, `ZQ`, `C-c C-k` or `SPC m k` cancels.
- Fetch, pull and push run in the background; `$` shows git's output. `?` lists the keys.
- `:Git ARGS` runs any git command and shows its output. `SPC g l` shows the log.
- Status is parsed from `git status --porcelain=v2 --branch -z`; parsed commands run synchronously (they are fast), network ones as jobs. Unusual file names are unquoted.

## Keys and options

`git-recent-commits`.

## Known gaps

- Nothing on screen says which keys exist; `?` has to be known.
- No staging of selected lines, rebase, merge or blame, and no refresh on save.
