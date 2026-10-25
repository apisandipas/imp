---
type: Effort
status: active
specs: ["[[spec/user-docs]]"]
issue: https://github.com/apisandipas/imp/issues/20
frozen:
  docs/specs/user-docs.md: f2ea3cb09d86
---
# User docs on the site

A docs section on the website: four guides, and a reference page per area generated from its spec.

## Approach

`tools/site-docs.py` turns `docs/guide/*.md` and `docs/reference/*.md` into HTML pages in `site/docs/` with pandoc, inside a template that uses the site's stylesheet, with a sidebar of every page grouped by area. The reference pages are written in plain English from the specs by a project skill, `.claude/skills/docs-page`, which holds how a page reads, and each records the hash of its spec so `--check` catches a spec that has moved on ([[0018-user-reference-pages-are-written-from-the-specs-and-checked]]). The first build published the specs as they are and showed they read as walls of text; that tool stays, reading pages instead of specs. The skill comes with the Org page, so the owner can settle the tone on one page before the rest are written; then the guides, one per task; then the pages, a group of areas per task. Until every page exists a missing one is only a warning; the last build task makes `--check` strict and runs it in `tools/check.sh`, with the Pages workflow and the Docs link, which only matter once the release merges into `main`.

## Tasks

- [x] `tools/site-docs.py` builds `site/docs/` from the specs: the site's look, a grouped sidebar, the Known gaps notice, spec links between pages and other links as plain text; `site/docs/` ignored by git; checked in a browser on the Org page.
- [ ] `tools/site-docs.py` builds the reference from `docs/reference/NAME.md` (its `from:` hash, a page's own "Not yet in imp" notice), `--stamp NAME` records a spec's hash and `--check` reports specs without pages, pages without specs and drift; the `docs-page` skill says how a page is written; `docs/reference/org.md` written with it and checked in a browser; the owner settles the tone on it.
- [ ] Guide: Install and first steps (`docs/guide/`), the docs' index page linking to it.
- [ ] Guide: Configuring init.scm.
- [ ] Guide: Packages.
- [ ] Guide: Coming from Emacs or Vim.
- [ ] Pages for the editing areas: vim, emacs-state, leader-and-modes, mouse, look, start-screen.
- [ ] Pages for the files and windows areas: files, buffers-and-windows, projects, dired, folding, terminals.
- [ ] Pages for the code areas: completion, completion-at-point, lsp, tree-sitter, dap.
- [ ] Pages for the rest of git and Org: git, git-blame, git-gutter, org-export.
- [ ] Pages for the extending areas: live-scheme-and-help, packages, kdl-config, wasm-plugins, daemon, shared-buffers, claude, mcp.
- [ ] `--check` is strict and `tools/check.sh` runs it; the Pages workflow installs pandoc and runs `tools/site-docs.py`, and also runs when `docs/guide`, `docs/reference` or the script change; the home page's nav and Docs link go to `docs/`; `site/CONTEXT.md` says how the docs are built.
- [ ] The owner has read the docs through in a browser.
