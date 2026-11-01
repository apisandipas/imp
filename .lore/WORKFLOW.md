# Workflow

How imp uses lore. The `lore-*` skills read this file before they act, so editing it, and the skills, changes the process. The `lore` CLI only enforces mechanics: links, citations, anchors, superseding and freezing.

## Notes

- **Spec** (`docs/specs`): what an area of imp does, its keys and options, and what it leaves out. `draft` while it is worked out, `accepted` once the owner agrees, `retired` when it no longer applies. Specs are edited in place. `issue:` names the GitHub issue it came from, if any.
- **Effort** (`docs/efforts`): one piece of work against one or more specs, built on one `feat/` branch. It names the specs in `specs:` and the issue it closes in `issue:`, and lists its tasks as a Markdown checklist. `planned`, then `active`, then `done`.
- **Decision** (`docs/decisions`, numbered): a choice, the context that forced it, and its consequences. Record one only when the choice is hard to reverse, would surprise a later reader, and came from a real trade-off; a convention or rule goes in a `CONTEXT.md` instead. Once `accepted` it is never edited; a change of mind is a new decision made with `lore new Decision "<title>" --supersedes <id>`.
- **Page** (`docs/reference`) and **Guide** (`docs/guide`): the user docs on the website. A page is written from one spec by the `docs-page` skill; a guide is written by hand and names in `specs:` the specs it summarises. Both are frozen against their specs, so `lore check` says when one changes: rewrite the page, or read the guide against the change and fix it, then `tools/site-docs.py --stamp NAME` or `--stamp-guide NAME`.
- **CONTEXT.md**: what a directory holds, the rules for code in it, and limits that can't be fixed. It applies to everything beneath it. The root one says what imp is and how to work on it.

## Where work starts

Ideas and bugs arrive as GitHub Issues, and GitHub, not `lore next`, is the list of what to do next. An issue is the problem and the discussion; a spec is what was agreed; an effort is the work; the PR says `Closes #N`, so the issue closes when the work ships, not when its spec is accepted. Small work needs only the issue.

- A feature issue is labelled `needs-spec` until its spec is accepted, then `specced`. The spec's `issue:` and the effort's `issue:` are the issue's URL, and the issue gets a comment linking the accepted spec.
- If discussion on an issue changes what was agreed, the spec changes with it.
- `docs/efforts/baseline.md` covers the specs written for code that existed before efforts were tracked.

## Size

Size the work before picking a skill. Most work is small, and small work skips the flow.

- **Small**: a bug fix, a rename, a dependency bump, or any change you can state in one sentence and land in one commit, as long as no accepted spec or decision says otherwise. It goes on a `fix/`, `chore/`, `docs/`, `refactor/` or `test/` branch from `develop`. No spec and no effort. Run `lore context` on each file, make the change, then run `tools/check.sh` and `lore check`. If it edits a spec the baseline effort covers (removing a known gap), run `lore freeze docs/efforts/baseline.md` too. If you made a choice a later reader would question, record it with **lore-decide**.
- **Feature**: anything that changes what a spec says, adds behaviour a user would notice, or needs more than one commit. It goes on a `feat/` branch from `develop` and uses the flow below.

When it is unclear, ask the owner. If small work grows past one commit, stop and start a spec.

## Flow

1. **lore-spec**: write or revise a spec until the owner accepts it.
2. **lore-plan**: create an Effort for an accepted spec, break the work into checklist tasks, and `lore freeze` it.
3. **lore-build**: take the first open task, do it, check it off. One task at a time; stop when the owner asked for one.
4. **lore-ship**: with every task checked, confirm `tools/check.sh` and `lore check` pass, mark the Effort `done`, update any `CONTEXT.md` the work changed, and merge the branch into `develop` with `--no-ff`.

**lore-decide** records a decision at any step, whenever a choice would surprise a later reader. **lore-next** runs `lore next` to say which step comes next; use it after a break or in a fresh session.

## Rules

- Before editing a file, run `lore context <file>` and follow the notes it lists.
- When code follows a decision a reader might question, cite it in a comment: `; see lore:<id>` in Scheme, `// see lore:<id>` in Rust, where `<id>` is a name like `decision/0006`. Only there; don't sweep the codebase for citations.
- If a spec changes during an Effort, `lore check` reports drift. Revisit the plan, then run `lore freeze <effort>` again.
- Run `tools/check.sh` and `lore check` before committing.
