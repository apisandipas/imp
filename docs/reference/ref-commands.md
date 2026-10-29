---
type: Page
spec: "[[spec/commands]]"
frozen:
  docs/specs/commands.md: 31bb6b804788
---
# Commands

Everything you can run in imp is a command with one name, such as `install-grammars` or `org-agenda`. Run it with `M-x`, or type it after `:` like a Vim command.

## Running a command

Press `M-x` (or `SPC :`, or `SPC SPC`), type part of a name, and press `<ret>`. The menu shows each command's keys and what it does.

The `:` line runs commands too. Type the whole name: `:org-agenda`. Vim's own commands, such as `:w`, `:s` and `:grep`, work as in Vim, and win when a command has the same name. Vim's short forms, like `:e` for `:edit`, work only for those. A name that is neither says `not an editor command`.

As you type after `:`, the menu offers command names beside Vim's, each with what it does. `<tab>` completes them.

## Giving a command its answer

Many commands ask a question, such as which grammar to install or which format to export to. From `M-x` they ask in the minibuffer. After `:`, you can give the answer straight after the name:

| Type | What happens |
|---|---|
| `:install-grammar ruby` | Installs the Ruby grammar |
| `:org-export html` | Exports the Org file to HTML |
| `:git log --oneline` | Runs `git log --oneline` |
| `:load-theme` | Asks which theme, as `M-x load-theme` does |

The text answers the command's first question only. If a command asks nothing, it runs and then says `NAME takes no argument`.

## Counts

A number before the name is a count, as a count typed before a key is: `:3next-diagnostic` moves three diagnostics on, as `3]d` does. Any other range, such as `%` or a visual selection's `'<,'>`, says `NAME takes no range`, and the command doesn't run.

## Old names

Some features used to have their own `:` names. They're commands now, and the old names are gone:

| Was | Now |
|---|---|
| `:Git`, `:G` | `git` (empty shows the status) |
| `:OrgAgenda`, `:OrgCapture`, `:OrgExport` | `org-agenda`, `org-capture`, `org-export` |
| `:GitBlame`, `:GitGutter`, `:FileTree` | `git-blame-mode`, `git-gutter-mode`, `file-tree` |
| `:start`, `:repl`, `:diagnostics` | `start-screen`, `repl`, `list-diagnostics` |
| `:packages`, `:package-update` | `list-packages`, `package-update` |
| `:mode` | `set-major-mode` |
| `:theme` | `load-theme` (`:colorscheme` still works) |
| `:fd` | `find-definition` |
| `:ev` | `eval` (`:eval EXPR` still works) |

`eval`, `kill-server`, `lsp-info`, `lsp-log`, `lsp-restart`, `lsp-stop`, `mcp-log`, `syntax-tree`, `describe-key`, `describe-function` and `apropos` keep their names, and now run from `M-x` too.

## Commands of your own

Define one in `init.scm` with a name and a docstring, which `M-x` shows. See [Configuring init.scm](configuring.md):

```scheme
(define-command! 'hello
  (lambda (count) "Say hello." (message "hello")))
```

It runs as `M-x hello` or `:hello`. If it asks a question, `:hello TEXT` answers it.
