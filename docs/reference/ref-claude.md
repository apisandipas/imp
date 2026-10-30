---
type: Page
spec: "[[spec/claude]]"
frozen:
  docs/specs/claude.md: ea885bd760a5
---
# Claude Code

imp runs Claude Code beside your code, in a terminal window down the right. Each project gets its own Claude, and you can send it code from your buffers.

## Showing and hiding Claude

Press `M-a` (or `SPC a a`) to show this project's Claude, starting it the first time. Press `M-a` inside it to hide it again. Hidden, it keeps running, so it's still there when you come back. It works like the [project's terminal](ref-terminals.md#the-projects-terminal) (`SPC o t`), which shares its window when both are on the right.

Claude takes the right 40% of the screen. Its place is a popup rule, so you can move it in `init.scm`:

```scheme
(define-popup-rule! "*claude" 'side 'bottom 'size 0.3)
```

## Sending code to Claude

| Key | What it does |
|---|---|
| `SPC a s` | Send the selection, or the current line |
| `SPC a b` | Send the whole buffer |
| `SPC a f` | Send a reference to the file, as `@path`, for Claude to read |

What you send is pasted into Claude's prompt, labelled with its file and lines as `path:lines`. Nothing is submitted: add what you want done, and press `<ret>`. To send code to your project's shell to run instead, use `SPC o s` ([terminals](ref-terminals.md#sending-text-to-the-terminal)).

Claude Code drops anything typed while it starts up. A new Claude only gets your text a moment after it's ready, `claude-settle-ms` (1000 ms) later. If text sent to a new Claude goes missing, raise it in `init.scm`:

```scheme
(set! claude-settle-ms 2000)
```

## Options

| Option | Default | What it does |
|---|---|---|
| `claude-command` | `"claude"` | The program to run for each project |
