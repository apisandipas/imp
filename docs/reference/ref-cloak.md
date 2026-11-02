---
type: Page
spec: "[[spec/cloak]]"
frozen:
  docs/specs/cloak.md: 2f3ffb4d8cb4
---
# Cloak

The `cloak` package draws the secret values in `.env` files as a row of `*`, so someone watching your screen doesn't see them. Only the drawing changes: the file, what you save and what you yank keep the real values.

## Not yet in imp

- Places that show a line's text still show it plainly: `:reg`, `:marks`, `:print` (and `:g` with `p`, `:number`).
- `M-x search-project` results and git popups (a diff of an env file) show the file's real lines, as does a terminal running `cat .env`.
- Tools that read the buffer for an agent (MCP, `claude`) get the real text.
- A new buffer first saved under a matching name (`:w .env`) isn't cloaked until you open it again or turn `cloak-mode` on.
- A value that runs over several lines is masked only on its first line.

## Turning it on

Add the package to your `init.scm`:

```scheme
(use-package! 'cloak)
```

From then on, files named `.env`, `.env.local`, `.env.production`, `prod.env` or `.envrc` are cloaked as they open. Files that are already open are cloaked when the package loads, and so is a file you rename to such a name with `M-x rename-file`.

A cloaked buffer draws everything after the first `=` on each line as `*`, one per character:

```
API_KEY=sk-123          is drawn    API_KEY=******
export TOKEN="abc"      is drawn    export TOKEN=*****
# no equals sign        is drawn    # no equals sign
```

The mask takes the same room as the text, so the cursor, wrapping and clicks work as usual, and you can edit a value as normal. The mask does show how long each value is. A comment with a `=` in it is masked too.

| Key or command | What it does |
|---|---|
| `SPC t c`, `M-x cloak-mode` | Turn cloaking on or off in this buffer |
| `M-x cloak-reveal-line` | Show the cursor's line plainly until the cursor leaves it |

## Looking at one value

`M-x cloak-reveal-line` shows the line the cursor is on. Move off the line, or to another buffer, and it is masked again.

To always see the line you are on, turn on `cloak-reveal-cursor-line`:

```scheme
(use-package! 'cloak
  'config (lambda () (set-option! 'cloak-reveal-cursor-line #t)))
```

## Copying and saving

The text in the buffer is never changed. `:w` saves the real values, `y` yanks them, and `p` pastes them, so you can copy a value out of a cloaked file.

## Completion

While a buffer is cloaked, its words are left out of the completion menu, in that buffer and in every other one, and out of the word completion at the `/` and `?` prompts. Turning `cloak-mode` off gives them back.

## Other files and patterns

`cloak-file-patterns` lists the file names to cloak. A pattern is matched against the file's name without its folder: `*` matches any run of characters and `?` any one. A change to it applies to files opened afterwards.

`cloak-pattern` is a Vim pattern for what to mask. Its groups are masked, or the whole match when it has none. To cloak YAML-style `key: value` lines as well:

```scheme
(set-option! 'cloak-file-patterns '(".env" ".env.*" "*.env" ".envrc" "secrets.yaml"))
(set-option! 'cloak-pattern "[=:] *\\(.\\+\\)")
```

Changing `cloak-pattern`, `cloak-mask-char` or `cloak-reveal-cursor-line` updates cloaked buffers at once.

## Options

| Option | Default | What it does |
|---|---|---|
| `cloak-file-patterns` | `(".env" ".env.*" "*.env" ".envrc")` | File names whose buffers are cloaked as they open |
| `cloak-pattern` | `=\(.\+\)` | What to mask: everything after a line's first `=` |
| `cloak-mask-char` | `"*"` | The character drawn in place of each character of a value |
| `cloak-reveal-cursor-line` | `#f` | Show the cursor's line plainly |
