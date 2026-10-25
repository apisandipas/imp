---
type: Page
spec: "[[spec/git-blame]]"
frozen:
  docs/specs/git-blame.md: 5d440041ec6f
---
# Git blame

Git blame shows who last changed the line you're on, and when, at the end of the line. It works as GitLens does in VSCode.

## Turning it on

Git blame is an opt-in package. Load it near the top of your `init.scm`:

```scheme
(use-package! 'git-blame)
```

It then turns on in every file you open that's in a git repository. Outside a repository, or for a file git doesn't track, nothing shows.

## Seeing a line's commit

Rest the cursor on a line in normal state. After half a second, the commit that last changed the line shows after it:

```
Bryan Paronto, 3 days ago • Add x
```

That's the author, how long ago, and the commit's subject. A line you haven't committed yet says `Not committed yet`.

The blame goes away when you move off the line, change the buffer, or enter insert state. It comes back once the cursor rests again. Unsaved edits don't confuse it: it blames the text as it is in the buffer.

## Turning it off

Press `SPC g b`, or type `:GitBlame`, to turn blame off in the current buffer. Do it again to turn it back on.

There's no blame of every line at once. For that, `:Git blame` shows git's own output (see [Git](ref-git.md)).

## Changing how it looks

The text is drawn in the `git-blame` face. Change it in `init.scm`:

```scheme
(set-face! "git-blame" "fg=#888888 italic")
```

## Options

| Option | Default | What it does |
|---|---|---|
| `git-blame-delay` | `500` | How long, in milliseconds, the cursor rests on a line before its blame shows |
