---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/20
summary: "The user documentation on the website: guides for learning imp, and a plain-English reference page for each area, written from its spec."
---
# User documentation

The website gets a documentation section for people using imp, not working on it, as Helix's book and Doom Emacs's docs are. Guides teach imp from the start; a reference page for each area is written in plain English from that area's spec, and checked against it so the two can't drift apart.

## Behaviour

- The site has a docs section at `docs/` (`https://apisandipas.github.io/imp/docs/`). Every docs page has the site's look, a sidebar listing every page, and a link back to the home page.
- The home page's **Docs** link and its nav go to the docs section.
- **Guides**, written by hand in `docs/guide/*.md`, in this order:
  - **Install and first steps:** installing imp, opening and saving files, the Vim keys it adds to, `SPC` and `M-x`, and getting help (`SPC h k`, `SPC h f`).
  - **Configuring init.scm:** options, keys, commands, hooks and themes, and redefining things while imp runs.
  - **Packages:** the bundled opt-in packages, loading them with `use-package!`, and writing your own.
  - **Coming from Emacs or Vim:** what carries over, Emacs state, and where imp differs.
- **Reference:** one page per area, in `docs/reference/NAME.md`, written in plain English from the spec `docs/specs/NAME.md` by the `docs-page` skill ([[0018-user-reference-pages-are-written-from-the-specs-and-checked]]). Every spec but this one has a page. The sidebar groups them by area: editing, files and windows, code, git and Org, and extending imp.
  - A page is for someone using imp: short sentences, one idea per paragraph, sub-headings by task ("Folding headings", "Dates"), and tables for keys and options. It says what to press and what happens, not how imp does it.
  - What the area can't do yet, from the spec's Known gaps, shows as a notice at the top of the page ("Not yet in imp"), each gap with its issue link, so a user knows what is missing before reading on (the Org agenda's, for one).
  - A page links to other areas' pages, never to decisions or efforts.
  - Each page records the hash of the spec it was written from. `tools/site-docs.py --check` fails when a spec has no page, a page has no spec, or a spec has changed since its page was written; the page is then rewritten with the skill, and `--stamp NAME` records the new hash. `tools/check.sh` runs the check.
- The docs are built by `tools/site-docs.py`, which turns the guides and reference pages into HTML with pandoc, inside the site's template. The Pages workflow runs it before publishing, so the generated pages are never committed.
- The docs describe the release they are published with. They are written on `develop` and go live when a release merges `develop` into `main`.
- A docs page works without JavaScript and reads well on a phone.

## Out of scope

- Search, beyond the browser's own find.
- Docs for each past release, or a version switcher.
- Contributor docs: decisions, efforts, `CONTEXT.md` and the lore workflow stay in the repository.
- An API reference for every Scheme function; `SPC h f` shows a function's docs in imp.
- Translations.

## Known gaps
