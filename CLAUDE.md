imp is an Emacs-flexible, Vim-first editor: a small Rust core with the
editor itself written in Steel Scheme (`runtime/*.scm`).

Its notes are lore notes. Start with `CONTEXT.md` at the root and
`.lore/WORKFLOW.md`, which says how work is sized and done; run
`lore context FILE` before editing a file (the hook does this) and follow
the notes it lists. Decisions are in `docs/decisions`, what each area does
in `docs/specs`, and the rules for each directory in its `CONTEXT.md`.
Work is tracked in GitHub Issues.

Work happens on a `type/slug` branch from `develop`, merged back with
`--no-ff`; `main` changes only for releases and website updates. Run
`lore check` and the affected tests before each commit, and the full
`tools/check.sh` (tests, clippy, fmt) once before pushing a branch.
