---
type: Page
spec: "[[spec/lsp]]"
frozen:
  docs/specs/lsp.md: 0515c939262d
---
# Language servers

A language server knows your code: it finds errors, jumps to definitions, renames across files and offers completions. imp starts one for you when you open a file it has a server for, if the server is installed. A slow server never holds up your typing.

## Not yet in imp

- Repeating a completion with `.` replays it as backspaces and the typed word, not as the completion.

## Servers imp knows

These start by themselves when they're installed:

| Language | Server |
|---|---|
| Rust | `rust-analyzer` |
| TypeScript and JavaScript | `tsgo`, else `typescript-language-server`, else `tsc --lsp` |
| Nix | `nil` |
| Markdown | `marksman` |
| Python | `pyright` |

imp finds the project's root by looking up from the file for a marker such as `Cargo.toml` or `.git`. One server runs per project, shared by all its files.

## Errors and warnings

The server's diagnostics are underlined in the text, with a sign in the gutter. In normal mode, the message for the cursor's line shows on the status line.

| Key | What it does |
|---|---|
| `]d` | Go to the next diagnostic |
| `[d` | Go to the previous diagnostic |
| `SPC c x` or `M-x list-diagnostics` | Pick a diagnostic from any file and go to it |

While you type, the diagnostics stay as they were. The new ones show when you leave insert mode, so half-typed words don't flash as errors. Until the server sends new ones, the old ones move with the text as you edit.

## Finding your way and changing code

| Key | What it does |
|---|---|
| `K` | Show what the server says about the symbol at the cursor |
| `gd` | Go to its definition |
| `gr` | Pick one of its references from a menu and go to it |
| `SPC c r` | Rename it, in every file the server knows of |
| `SPC c a` | Pick one of the server's code actions, such as a quick fix |
| `SPC c f` | Format the buffer |

There's no signature help and no inlay hints.

## Completion

In insert mode, the server's names show in the completion menu at the cursor. The menu opens by itself when you type a letter, or a character the server asks for, often `.` after a name. You can also open it with `C-n`, `C-p` or `C-x C-o`.

Snippets from the server expand when you accept them. See [Completion while typing](ref-completion-at-point.md) for the keys in the menu.

## Managing servers

| Command | What it does |
|---|---|
| `M-x lsp-info` | List the running servers |
| `M-x lsp-log` | Show what the servers have logged |
| `M-x lsp-restart` or `SPC c R` | Restart this buffer's server |
| `M-x lsp-stop` | Stop this buffer's server |

## A server of your own

Set a major mode's server in `init.scm`. Give the command, the files that mark a project's root, and the language's name:

```scheme
(define-language-server! 'rust-mode "rust-analyzer" '("Cargo.toml" ".git") "rust")
```

The command can be a list of commands instead. imp uses the first one that's installed.

## Options

| Option | Default | What it does |
|---|---|---|
| `lsp` | `#t` | Use language servers; `#f` starts none |
| `lsp-auto-complete` | `#t` | Open the completion menu by itself where a server is running |
| `lsp-change-delay` | `200` | Milliseconds of quiet before your changes are sent to the server |
| `lsp-diagnostics-in-insert` | `#f` | Show new diagnostics while you type, not only when you leave insert mode |
