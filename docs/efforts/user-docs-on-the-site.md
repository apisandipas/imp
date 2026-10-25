---
type: Effort
status: active
specs: ["[[spec/user-docs]]"]
issue: https://github.com/apisandipas/imp/issues/20
frozen:
  docs/specs/user-docs.md: d78f55606ccc
---
# User docs on the site

A docs section on the website: four guides, and a reference page per area generated from its spec.

## Approach

`tools/site-docs.py` reads `docs/guide/*.md` and `docs/specs/*.md` and writes HTML pages into `site/docs/` with pandoc, inside a template that uses the site's stylesheet, with a sidebar of every page grouped by area ([[0017-the-user-reference-is-generated-from-the-specs]]). For a spec it keeps the summary, Behaviour and Keys and options, puts Known gaps first as a "Not yet in imp" notice, turns links to specs into links to their pages and other note links into plain text. `site/docs/` is ignored by git; the Pages workflow installs pandoc and runs the script before publishing. The tool comes first, with one spec, so the look is settled before the writing starts; then the guides, one per task; then the specs, a group of areas per task, rewritten to read well for users without losing what contributors need. The workflow and the Docs link come last, since they only matter once the release merges into `main`.

## Tasks

- [x] `tools/site-docs.py` builds `site/docs/` from the specs: the site's look, a grouped sidebar, the Known gaps notice, spec links between pages and other links as plain text; `site/docs/` ignored by git; checked in a browser on the Org page.
- [ ] Guide: Install and first steps (`docs/guide/`), the docs' index page linking to it.
- [ ] Guide: Configuring init.scm.
- [ ] Guide: Packages.
- [ ] Guide: Coming from Emacs or Vim.
- [ ] The user pass on the editing specs: vim, emacs-state, leader-and-modes, mouse, look, start-screen.
- [ ] The user pass on the files and windows specs: files, buffers-and-windows, projects, dired, folding, terminals.
- [ ] The user pass on the code specs: completion, completion-at-point, lsp, tree-sitter, dap.
- [ ] The user pass on the git and Org specs: git, git-blame, git-gutter, org, org-export.
- [ ] The user pass on the extending specs: live-scheme-and-help, packages, kdl-config, wasm-plugins, daemon, shared-buffers, claude, mcp.
- [ ] The Pages workflow installs pandoc and runs `tools/site-docs.py`, and also runs when `docs/guide`, `docs/specs` or the script change; the home page's nav and Docs link go to `docs/`; `site/CONTEXT.md` says how the docs are built.
- [ ] The owner has read the docs through in a browser.
