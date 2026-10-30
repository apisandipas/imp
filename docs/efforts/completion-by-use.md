---
type: Effort
status: active
specs: ["[[spec/completion-by-use]]"]
issue: https://github.com/apisandipas/imp/issues/70
frozen:
  docs/specs/completion-by-use.md: adc2d1d59a46
---
# Completion by use

## Approach

`completion.scm` keeps a history per kind of menu (its completion category, or its prompt when it has none): each candidate's pick count and when it was last picked. It's read from the state directory once, and written back after each pick. When a menu opens, each candidate gets its score (count × the age weight), and a new Rust `fuzzy-filter-ranked` takes those scores beside the candidates: with nothing typed it puts the scored ones first, and once something is typed it uses them between the match score and the length. Menus opt out by setting `*completion-ranked*` to #f, as they set `*completion-category*`, and `find-file` gives a key function so files are remembered by full path.

## Tasks

- [x] `fuzzy-filter-ranked` in `fuzzy.rs`: scored candidates first with nothing typed (highest first, the menu's order after), and the score between the match and the length once something is typed. Unit tests.
- [x] The history: recorded per menu on each pick, kept in the state directory (500 per menu, by score), scored by count and age; every `completing-read` menu ranked by it except `recent-files` and `switch-buffer`; `find-file` by full path; `completion-history` off stops it; `M-x clear-completion-history`. Tests, and a section in the completion reference page.
