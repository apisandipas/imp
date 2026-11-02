---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/152
summary: "The cloak package draws the values in .env and similar files as a row of mask characters, so they aren't shown to someone watching your screen, while the text itself stays as it is."
---
# Cloak

A bundled package, after Emacs's [cloak-mode](https://github.com/erickgnavar/cloak-mode) and Neovim's [cloak.nvim](https://github.com/laytan/cloak.nvim), that draws the secret values in `.env` and similar files as a row of `*`, so a screen share, a screencast or someone over your shoulder doesn't see them. Only how the buffer is drawn changes: the text, what is saved and what is yanked are the real values. It is off until loaded ([[0011-non-essential-features-are-opt-in-packages]]), with `(use-package! 'cloak)`, and draws on a masking primitive the core adds for it.

## Behaviour

### Masking (core)

- `(buffer-mask-pattern! layer pattern mask reveal)` draws what `pattern`'s groups match in the current buffer (all of a match when it has no groups), as `buffer-conceal-pattern!` takes them, as `mask` (a string; its first char is used, and must be one cell wide) instead of the text. `pattern` is a Vim pattern, as the search takes; `""` stops masking that layer. Matches are found as the lines are drawn, so masking follows edits.
- Each masked char is drawn as one mask char per cell it takes: a tab as several, a wide char as two, a combining mark as none. So a masked line is laid out exactly as the plain one: the cursor, wrapping, clicks and columns are where they would be without it, and a value's length shows.
- With `reveal` true, the line the cursor is on in each window showing the buffer is drawn plain; with it false, every line is masked.
- Masks are drawn in the terminal and the window client alike, in every window showing the buffer, on a closed fold's first line, under search highlights, the visual selection and the cursor line. They are drawn for every client of a daemon: none sees the text.
- The text is never changed: saving, yanking, `:%s`, undo and every other command use the real text.

### Words in completion (core)

- The local option `completion-words` (default `#t`) says whether a buffer's words are offered by completion. Off, the words source offers none of its words in any buffer, itself included, nor does the search prompt's word completion (`/`, `?`) while it is the current buffer.

### The package

- `cloak-mode` is a minor mode of the buffer. `M-x cloak-mode` and `SPC t c` turn it on and off in the current buffer.
- Loading the package turns `cloak-mode` on in every buffer already open, and in every buffer that opens later or is renamed (`:w NAME`, `:saveas`), whose file name matches one of `cloak-file-patterns`. The patterns are globs matched against the file's name without its directory: `*` matches any run of chars and `?` any one. The default, `(".env" ".env.*" "*.env" ".envrc")`, covers `.env`, `.env.local`, `.env.production`, `prod.env` and direnv's `.envrc`; `env.txt` and `.environment` don't match.
- While it is on, what `cloak-pattern`'s groups match is masked with `cloak-mask-char`. The default pattern, `=\(.\+\)`, masks everything after the first `=` on a line: `API_KEY=sk-123` is drawn `API_KEY=******`, `export TOKEN="abc"` as `export TOKEN=*****`. A line with no `=` is drawn plain, and a comment with a `=` in it is masked too.
- With `cloak-reveal-cursor-line` on (off by default), the cursor's line is drawn plain, as cloak.nvim's `cloak_reveal_cursor_line`.
- `M-x cloak-reveal-line` shows the cursor's line plain until the cursor leaves that line or the buffer, then masks it again, for a quick look at one value (cloak.nvim's `CloakPreviewLine`). With `cloak-mode` off it says `cloak-mode is off`.
- While it is on, the buffer's `completion-words` is off, so its values never appear in a completion menu, in it or in any other buffer. Turning the mode off puts the option back as it was.
- Changing `cloak-mask-char`, `cloak-pattern` or `cloak-reveal-cursor-line` with `set-option!` or `:set` takes effect at once in every buffer where the mode is on.
- Turning `cloak-mode` off draws the buffer plain. Changing `cloak-file-patterns` affects buffers opened after.
- The text is never changed: `:w` saves the real values, and `y` yanks them, so a value can be copied out of a cloaked buffer and pasted.

## Keys and options

| Key, command or option | Default | What it does |
|---|---|---|
| `SPC t c`, `M-x cloak-mode` | | Turn masking on or off in this buffer |
| `M-x cloak-reveal-line` | | Show the cursor's line plain until the cursor leaves it |
| `cloak-file-patterns` | `(".env" ".env.*" "*.env" ".envrc")` | Globs of file names whose buffers turn `cloak-mode` on |
| `cloak-pattern` | `=\(.\+\)` | Vim pattern; what its groups match is masked |
| `cloak-mask-char` | `"*"` | The char drawn in place of each cell of a value |
| `cloak-reveal-cursor-line` | `#f` | Draw the cursor's line plain |
| `completion-words` (core, local) | `#t` | Offer this buffer's words in completion |
| `(buffer-mask-pattern! layer pattern mask reveal)` (core) | | Draw what a pattern matches as a mask char |

## Out of scope

- A fixed-length mask that hides how long a value is: a mask the length of the value keeps the layout, cursor and clicks exact.
- Patterns per major mode or per file pattern, as Emacs's cloak-mode keys them: one pattern for every cloaked buffer.
- Masking values in other kinds of file (YAML `key: value`, JSON) by default; `cloak-pattern` can be set for them.
- Turning cloaking on in every buffer at once, as cloak.nvim's `CloakEnable`.
- Keeping secrets from tools that read the file or the buffer's text, rather than looking at the screen.

## Known gaps

Places that still show a cloaked buffer's real text, because they show text the user asked for or read the text rather than the drawn frame:

- `:reg` and the paste of a yanked value, which are meant to be real.
- `:marks`, `:print` (and `:g` with `p`, `:number`), which print a line's text.
- `M-x search-project` results and `git` output popups (a diff or blame of an env file) show the file's lines from disk or git.
- A terminal buffer running `cat .env`, and tools that read the buffer for an agent (MCP, `claude`).
- A value continued over several lines (a quoted multi-line value) is masked only on its first line by the default pattern.
