---
type: Page
spec: "[[spec/git-gutter]]"
frozen:
  docs/specs/git-gutter.md: 50690fac14f4
---
# Git gutter

Git gutter puts a coloured bar beside each line that differs from git. You see at a glance what you've added, changed and removed, as in VSCode and gitsigns.

## Turning it on

Git gutter is an opt-in package. Load it near the top of your `init.scm`:

```scheme
(use-package! 'git-gutter)
```

It then turns on in every file you open that git tracks. A file outside a repository, or one git doesn't track, gets no bars.

## Reading the bars

The bars sit in a narrow column between the line numbers and the fold column. The column stays while git gutter is on, even with no changes, so your text doesn't shift.

| Mark | Colour | Means |
|---|---|---|
| `┃` | Green | An added line |
| `┃` | Orange | A changed line |
| `▁` | Red | Lines were removed below this one |
| `▔` | Red, on the first line | Lines were removed at the top of the file |

When a block of new lines replaces old ones, every new line counts as changed.

The buffer is compared with git's index, so changes you've staged aren't marked. Unsaved edits are: the bars follow the text as it is in the buffer. They update shortly after you stop typing, after a save, and when you come back to the buffer.

No word diff: changes are marked per line.

## Jumping to changes

| Key | What it does |
|---|---|
| `]h` | Go to the next changed block |
| `[h` | Go to the previous changed block |

Each lands on the block's first line and takes a count: `3]h` jumps three blocks on. Past the last block, the cursor stays put and imp says `no more hunks`.

## Turning it off

Run `M-x git-gutter-mode` to turn git gutter off in the current buffer. The column and its bars go. Run it again to turn it back on.

## Changing the colours

The bars use the faces `git-gutter.added`, `git-gutter.changed` and `git-gutter.removed`. Change one in `init.scm`:

```scheme
(set-face! "git-gutter.changed" "fg=#e5c07b")
```

## Options

| Option | Default | What it does |
|---|---|---|
| `git-gutter-delay` | `300` | How long, in milliseconds, after you stop typing the bars update |
