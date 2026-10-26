---
status: accepted
summary: "Project roots, finding files and buffers in a project, and project search into quickfix."
anchors: [runtime/project.scm, crates/imp-server/tests/project.rs]
---
# Projects

## Behaviour

- A project is the nearest directory above the file with a marker in `project-markers` (tried in order). Visited projects are remembered in the state directory.
- `SPC p f` finds a file in the project, `SPC p p` switches project and then finds a file, `SPC p b` shows its buffers.
- `SPC s p` (offering the word at the cursor) or `:grep PATTERN` searches with `rg`, falling back to `grep -rnI`, into `*grep*` along the bottom.
- Quickfix as in Vim: `:grep` jumps to the first match and `:grep!` doesn't; `:copen :cn :cp :cfirst :clast :cc ]q [q`; Vim's E42 and E553 messages.

## Keys and options

`project-markers`, `grepprg` (default `rg --vimgrep --sort=path`).
