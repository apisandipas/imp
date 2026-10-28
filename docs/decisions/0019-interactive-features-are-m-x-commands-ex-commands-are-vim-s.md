---
type: Decision
status: accepted
---
# Interactive features are M-x commands; ex commands are Vim's

## Context

imp names things in three ways: Scheme functions (`define`, called from `init.scm` and `:eval`), commands (`define-command!`, reached from M-x, keys and SPC), and ex commands (`define-ex!`, reached from `:` only). M-x is how imp is mainly used, but features kept arriving as ex commands only, often named in Neovim's style (`:TSInstallGrammar`, `:OrgAgenda`, `:GitBlame`), so M-x couldn't find them; and `:` didn't run commands, so the few reachable both ways (`describe-key`) were written twice. The owner found the split very confusing (issue #93). The alternatives were to keep both kinds and mirror every feature by hand, or to make ex commands the primary name, which suits Vim users but hides features from M-x.

## Decision

Every interactive feature is a command, defined with `define-command!` and named in kebab-case, so M-x finds it; `:NAME` runs the command `NAME` when no ex command of that name exists. Ex commands are defined only for Vim's own (`:w`, `:s`, `:map`, `:grep`, `:cnext`...), so Vim habits keep working; no new feature gets an ex-only name. A Scheme function for `init.scm` stays a separate thing: `install-grammar!` is called, `install-grammar` is run.

## Consequences

- One name for each feature, the same in M-x, SPC labels, help and the docs.
- Neovim-style names (`:TSInstallGrammar`, `:GitBlame`) are not used; their commands are kebab-case (`install-grammar`).
- Existing ex-only features must be converted, and `:` must fall back to commands; both are issue #93. Until then, a new feature is an M-x command only.
- A command that takes an argument asks for it (`completing-read`), since M-x passes only a count; `:NAME args` will have to pass the arguments to it.
