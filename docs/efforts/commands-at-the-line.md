---
type: Effort
status: done
specs: ["[[spec/commands]]"]
issue: https://github.com/apisandipas/imp/issues/93
frozen:
  docs/specs/commands.md: 31bb6b804788
---
# Commands at the : line

## Approach

The `:` side is a fallback at the end of `run-ex!` (`runtime/vim.scm`): when no ex command has the name, look it up with `command-proc` and run it with the count, as M-x does. Arguments ride on the prompt rather than on the command, so commands keep taking only a count ([[0019-interactive-features-are-m-x-commands-ex-commands-are-vim-s]]). While a command started from `:` runs, `open-cmdline!` notes that a prompt opened; when the command returns with its prompt open, the text after the name is put in the prompt, its change handler runs (so `completing-read` narrows), and it is submitted as `<ret>` would. That covers `completing-read` and the free-text prompts alike, with no change to the commands. A command that never opened a prompt has already run by then, so "takes no argument" is said after it runs, as the spec says. The answer only applies while the command runs: a prompt opened later (after a background job, say) asks as usual. A command whose question isn't a prompt, such as `org-export`'s menu of keys, reads the text itself with `(command-argument)`, which also counts as answering it.

The renames follow, one area at a time, each converting the ex command into a command (or deleting the ex copy of one that exists), updating the tests that typed the old name, and the specs and reference pages that named it, in the same commit. `docs/reference/ref-commands.md` is written from the spec with the `docs-page` skill in the first task, and grows with each.

## Tasks

- [x] `:` runs commands: after the ex commands, `:NAME` runs command `NAME`; an ex command of the same name wins; only the full name; `not an editor command: NAME` otherwise. A number before the name is the count (`:3next-diagnostic`), and any other range says `NAME takes no range` without running it. With tests, and `docs/reference/ref-commands.md` written from the spec.
- [x] Arguments: text after the name answers the command's first prompt and submits it, narrowing a `completing-read` first (`:install-grammar ruby`, `:load-theme` with a name); without text the prompt asks as usual; a command that opened no prompt says `NAME takes no argument` once it has run. With tests for `completing-read`, a free-text prompt, no text, and a command that asks nothing.
- [x] Completion: the `:` line's menu and `<tab>` offer command names beside ex commands, each command with the first line of its docstring. With tests.
- [x] Git, LSP, MCP and syntax: `git` (asks for git's arguments; empty shows the status), `lsp-info`, `lsp-log`, `lsp-stop`, `mcp-log` and `syntax-tree` become commands with docstrings; `:Git`, `:G` and those ex commands, and the ex copies `:diagnostics` and `:lsp-restart`, are removed. Tests, the git, LSP, MCP and tree-sitter specs and reference pages updated.
- [x] Packages, modes and themes: `list-packages`, `package-update` (asks which package loaded from git), `set-major-mode` (asks which mode; empty shows the current one) become commands; `:packages`, `:package-update`, `:mode` and `:theme` are removed. Tests, the packages, leader-and-modes, look and modus-themes specs and pages, and the packages guide updated.
- [x] Org, git packages, file tree, start screen, REPL and help: the ex copies `:OrgAgenda`, `:OrgCapture`, `:OrgExport`, `:GitBlame`, `:GitGutter`, `:FileTree`, `:start`, `:repl`, `:describe-key`, `:describe-function`, `:apropos`, `:find-definition` and `:fd` are removed, leaving their commands; `:org-export html` exports. Tests, and the specs, reference pages and README that named them, updated.
- [x] Writing packages: `runtime/CONTEXT.md` and the packages guide say to define a command, not an ex command, and that `:NAME text` answers its prompt. No ex command outside Vim's own is left (`grep define-ex!` matches the spec's list), and no spec, page or guide names a removed one.
