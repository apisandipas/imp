---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/20
summary: "The user documentation on the website: guides for learning imp, and a reference for each area generated from its spec."
---
# User documentation

The website gets a documentation section for people using imp, not working on it, as Helix's book and Doom Emacs's docs are. Guides teach imp from the start; a reference page for each area is generated from that area's spec, so the docs and the specs can't drift apart.

## Behaviour

- The site has a docs section at `docs/` (`https://apisandipas.github.io/imp/docs/`). Every docs page has the site's look, a sidebar listing every page, and a link back to the home page.
- The home page's **Docs** link and its nav go to the docs section.
- **Guides**, written by hand in `docs/guide/*.md`, in this order:
  - **Install and first steps:** installing imp, opening and saving files, the Vim keys it adds to, `SPC` and `M-x`, and getting help (`SPC h k`, `SPC h f`).
  - **Configuring init.scm:** options, keys, commands, hooks and themes, and redefining things while imp runs.
  - **Packages:** the bundled opt-in packages, loading them with `use-package!`, and writing your own.
  - **Coming from Emacs or Vim:** what carries over, Emacs state, and where imp differs.
- **Reference:** one page per spec in `docs/specs`, except this one, generated from it. The sidebar groups them by area: editing, files and windows, code, git and Org, and extending imp.
  - The page's title is the spec's title, its first paragraph the spec's summary.
  - It shows the spec's Behaviour and Keys and options sections.
  - The spec's Known gaps show as a notice at the top of the page ("Not yet in imp"), each gap with its issue link, so a user knows what is missing before reading on (the Org agenda's, for one).
  - Out of scope, anchors and other frontmatter aren't shown.
  - A link to another spec goes to that area's reference page. A link to a decision, effort or other note becomes plain text.
- The specs are written to read well for users as well as contributors: plain statements of what imp does, keys and options named, nothing that only makes sense with the code open. Every spec gets this pass.
- The docs are built by `tools/site-docs.py`, which turns the guides and specs into HTML with pandoc, inside the site's template. The Pages workflow runs it before publishing, so the generated pages are never committed.
- The docs describe the release they are published with. They are written on `develop` and go live when a release merges `develop` into `main`.
- A docs page works without JavaScript and reads well on a phone.

## Out of scope

- Search, beyond the browser's own find.
- Docs for each past release, or a version switcher.
- Contributor docs: decisions, efforts, `CONTEXT.md` and the lore workflow stay in the repository.
- An API reference for every Scheme function; `SPC h f` shows a function's docs in imp.
- Translations.

## Known gaps
