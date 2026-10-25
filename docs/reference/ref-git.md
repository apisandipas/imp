---
type: Page
spec: "[[spec/git]]"
frozen:
  docs/specs/git.md: 78d3f472e9c2
---
# Git

imp has a Magit-style status buffer for git. From it you stage changes, commit, switch branches, stash, and pull and push, without leaving the editor.

## Not yet in imp

- The log, diff and commit buffers don't show key lines at the bottom.
- You can't stage selected lines, rebase, merge or blame from the status buffer.
- The status doesn't refresh when you save a file.

## The status buffer

Press `SPC g g`, or type `:Git`, to open the status of the current file's repository. It opens down the right of the screen.

From the top, it shows:

- **The head**: the branch you're on and its latest commit's subject.
- **The upstream**: how many commits you are ahead and behind.
- **Untracked**, **Unstaged** and **Staged** files.
- **Stashes**.
- **Recent commits**: the latest 10, or as many as `git-recent-commits` says.

The status refreshes when you come back to it. Press `gr` to refresh it by hand.

Two lines of the main keys sit at the bottom of the window. Press `?` for a menu of every key; pressing a key in it acts on the line under the cursor.

## Staging and discarding

Put the cursor on a file, or on a hunk of its diff, and press a key.

| Key | What it does |
|---|---|
| `<tab>` | Show or hide the file's diff, hunk by hunk |
| `s` | Stage the file or hunk |
| `u` | Unstage the file or hunk |
| `S` | Stage everything |
| `U` | Unstage everything |
| `x` | Discard the file or hunk, after asking |
| `<ret>` | Visit what's under the cursor: a file at its line, or a commit |

## Committing

Press `c` to open the commit menu.

| Key | What it does |
|---|---|
| `c c` | Commit what's staged |
| `c a` | Amend the last commit |
| `c e` | Extend the last commit: amend it, keeping its message |

The message opens in a buffer of its own. Write it, then commit or cancel:

| Key | What it does |
|---|---|
| `ZZ`, `C-c C-c` or `SPC m c` | Commit |
| `ZQ`, `C-c C-k` or `SPC m k` | Cancel |

## Branches and stashes

| Key | What it does |
|---|---|
| `b b` | Check out a branch |
| `b c` | Create a branch and check it out |
| `z z` | Stash your changes |
| `z p` | Pop the stash |
| `z a` | Apply the stash |

## Pulling and pushing

| Key | What it does |
|---|---|
| `f f` | Fetch |
| `F F` | Pull |
| `F r` | Pull with `--rebase` |
| `P P` | Push |
| `P u` | Push, setting the upstream |
| `$` | Show git's output |

Fetch, pull and push run in the background, so you can keep editing. Press `$` to see what git printed.

## The log and diffs

| Key | What it does |
|---|---|
| `l` | Show the log, in the status buffer |
| `SPC g l` | Show the log, from anywhere |
| `d d` | Show the unstaged diff |
| `d s` | Show the staged diff |

Press `<ret>` on a commit in the log to see it.

## Running any git command

Type `:Git` with arguments to run any git command and see its output:

```
:Git log --oneline -5
```

## Options

| Option | Default | What it does |
|---|---|---|
| `git-recent-commits` | `10` | How many recent commits the status shows |
| `git-status-hints` | `#t` | Show the main keys at the bottom of the status window |
