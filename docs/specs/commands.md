---
type: Spec
status: accepted
summary: "One name for each interactive feature: an M-x command, which the : line also runs, with ex commands kept for Vim's own."
issue: https://github.com/apisandipas/imp/issues/93
---
# Commands

Every feature someone runs is a command with one kebab-case name, the same in M-x, `SPC` labels, help and the docs; the `:` line runs commands too, and ex commands are only Vim's own ([[0019-interactive-features-are-m-x-commands-ex-commands-are-vim-s]]).

## Behaviour

- **`:` runs commands.** When no ex command has the name typed, `:NAME` runs the command `NAME`, as M-x would. An ex command of the same name wins: `:terminal` is still Vim's. Only the full name runs a command; Vim's abbreviations (`:e` for `:edit`) stay for ex commands alone. A name that is neither says `not an editor command: NAME`, as now.
- **Arguments.** Text after the name answers the command's first question, as if typed at its prompt and submitted: `:install-grammar ruby` installs Ruby, `:org-export html` exports to HTML, and `:git log --oneline` runs `git log --oneline`. Without text the command asks in the minibuffer, as it does from M-x. A command only shows that it asks by opening a prompt while it runs, so text given to a command that asks nothing is reported once the command has run: `NAME takes no argument`.
- **Counts.** A number before the name is the command's count, as a count typed before its key would be: `:3next-diagnostic`. Any other range (`%`, `'<,'>`, `.,$`) says `NAME takes no range`, and the command doesn't run.
- **Completion.** The `:` line's menu and `<tab>` offer command names beside ex command names, each command with the first line of its docstring, as M-x shows it.
- **Ex commands are Vim's own.** `define-ex!` defines only commands Vim has, so habits carry over: `:w`, `:q`, `:e`, `:s`, `:g`, the `:map` family, `:set` and `:setlocal`, `:grep` and the quickfix commands (`:copen`, `:cnext`...), `:help`, `:colorscheme`, `:recover`, `:Explore`, `:terminal`, and the rest of Vim's that imp has. Vim's commands that imp also has as a command (`:terminal`, `terminal`) keep both.
- **The ex-only features become commands**, and their old ex names are removed (`:` then says `not an editor command`):

  | Was | Now |
  |---|---|
  | `:Git [args]`, `:G` | `git`: asks for git's arguments; empty shows the status (`git-status`) |
  | `:OrgAgenda` | `org-agenda` |
  | `:OrgCapture` | `org-capture` |
  | `:OrgExport FORMAT` | `org-export` |
  | `:GitBlame` | `git-blame-mode` |
  | `:GitGutter` | `git-gutter-mode` |
  | `:FileTree` | `file-tree` |
  | `:start` | `start-screen` |
  | `:repl` | `repl` |
  | `:diagnostics` | `list-diagnostics` |
  | `:lsp-info`, `:lsp-log`, `:lsp-restart`, `:lsp-stop` | `lsp-info`, `lsp-log`, `lsp-restart`, `lsp-stop` |
  | `:mcp-log` | `mcp-log` |
  | `:syntax-tree` | `syntax-tree` |
  | `:packages` | `list-packages` |
  | `:package-update NAME` | `package-update`: asks which package, from those loaded from git |
  | `:mode [NAME]` | `set-major-mode`: asks which major mode, from those defined; empty shows the current one |
  | `:theme NAME` | `load-theme` (`:colorscheme` stays, as Vim's) |
  | `:describe-key`, `:describe-function`, `:apropos`, `:find-definition`, `:fd` | `describe-key`, `describe-function`, `apropos`, `find-definition` |
  | `:eval EXPR`, `:ev` | `eval`: asks for a Scheme expression and evaluates it |
  | `:kill-server` | `kill-server` |

  Each new command has a docstring, so M-x and help describe it.
- **Writing a package.** `runtime/CONTEXT.md` and the packages guide say to define a command, not an ex command, and how its prompt gets `:NAME text`.
- The specs and reference pages that name an old ex command name its command instead.

## Keys and options

No new keys or options. `M-x` (and `SPC :`, `SPC SPC`) and `:` both run commands.

## Out of scope

- The WASM and shared-buffer prototypes (`:wasm`, `:wasm-log`, `:share`, `:join`, `:unshare`), behind cargo features and not in release builds, keep their ex commands until they leave prototype.
- Major modes as commands (`M-x ruby-mode`), as in Emacs: `set-major-mode` asks for one instead.
- Abbreviated command names at `:` (`:install-g`): completion fills them in.
- Deprecation messages or aliases for the removed ex names.
- Ranges passed to commands, beyond a count.

## Known gaps
