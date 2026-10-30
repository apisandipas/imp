---
type: Page
spec: "[[spec/completion-by-use]]"
frozen:
  docs/specs/completion-by-use.md: f4083d7f5e38
---
# Completion by use

Menus remember what you pick in them, and put what you use most and most recently first. Run a command from `M-x` a few times and it's at the top the next time you press `M-x`.

## What it changes

With nothing typed, what you've picked comes first, the most used and most recent at the top, and then everything else in the menu's usual order.

Once you type, the best matches still come first, and a name you type in full always comes first. Between two equally good matches, the one you use more comes first. So typing `find` puts `find-file` above `find-grep` if that's the one you run.

How much a pick counts fades with time: a pick from the last hour counts four times as much as one from last week, and one from last month half as much again.

## Which menus

Every menu that lists names to pick from: `M-x`, `SPC SPC` (`find-file`), `SPC p p`, the describe commands, themes, `SPC o l` and the rest. Each kind of menu keeps its own history, so a command you use often doesn't push a file up.

`SPC f r` (recent files) and `SPC b b` (switch buffer) already list things in the order you used them, so they keep it.

Files are remembered by their full path, so a file you open often comes first wherever you search from.

Completion while you type in insert state isn't a menu and is unchanged.

## Turning it off

The history is kept in imp's state directory, so it lasts across restarts. To forget it, run `M-x clear-completion-history`. To stop it altogether, so menus always show their own order:

```scheme
(set-option! 'completion-history #f)
```

## Options

| Option | Default | What it does |
|---|---|---|
| `completion-history` | `#t` | Remember what you pick in menus, and put it first |
