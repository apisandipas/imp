---
type: Effort
status: active
issue: https://github.com/apisandipas/imp/issues/59
specs: ["[[spec/org-agenda]]"]
frozen:
  docs/specs/org-agenda.md: 9736e77a7cbe
---
# Org agenda: views and the dispatcher

## Approach

The third of six efforts for issue #59 ([[org-agenda]]): *Other views*, and of *Views of the dated view* the spans and the grid (log mode and the clock report are effort 5).

The agenda buffer holds a view: a title and a list of blocks, each a dated span, a TODO list, a tags match or a search, with its own settings. Drawing a view draws each block's sections one after another through the same rows and layout, so every view lines up the same way and a custom command is just a list of blocks. The match and search syntaxes are parsed once into predicates over agenda entries. Moving with `[[` and `]]` moves the dated blocks.

Each task updates the reference page in the same commit.

## Tasks

- [x] Views as data: the agenda buffer holds a view of blocks, the dated view one of them, drawn as now; `SPC o a` becomes a prefix (`SPC o a a`, `M-x org-agenda-list`); with tests
- [ ] `gD`: a day, week, fortnight, month (from its first day) or year (from 1 January), and the grid on or off, kept until the agenda is opened again; with tests
- [ ] The TODO list, by priority then file order, and `T`'s list for one keyword; with tests
- [ ] Tags matches in Org's syntax (tags with `+ - & |`; `TODO`, `LEVEL`, `PRIORITY`, `CATEGORY` and properties compared with `= <> < > <= >=` against numbers, strings and regexps), done entries in or out; with tests
- [ ] Search: words in a heading or its text, ignoring case, with `+word`, `-word`, `"phrase"` and `{regexp}`; with tests
- [ ] The dispatcher (`SPC o A`, `M-x org-agenda`, `:OrgAgenda`): `a t T m M s n`, `<` and `< <` to limit to the file or subtree; `SPC o a t`, `SPC o a m`, `SPC o a s`; with tests
- [ ] Custom commands and block agendas: `define-agenda-command!` with `agenda`, `todo`, `tags`, `tags-todo` and `search` blocks and their `span` and `header` settings, in the dispatcher; `[[` and `]]` move the dated blocks; with tests
- [ ] Read the reference page through against the spec and the keys, and check the which-key labels
- [ ] The owner has looked at the views and the dispatcher
