---
type: Effort
status: active
specs: ["[[spec/org-export]]", "[[spec/org]]"]
issue: https://github.com/apisandipas/imp/issues/54
frozen:
  docs/specs/org-export.md: de7f2ecf0f8c
  docs/specs/org.md: 7120a0ea277d
---
# Org export package

An Org buffer exports to seven formats through pandoc, from a two-level menu like Org's dispatcher.

## Approach

All Scheme, in a bundled package `packages/org-export` ([[0011-non-essential-features-are-opt-in-packages]]); no Rust is needed. One function builds the text to export (the buffer, or with the toggles its subtree, its visible lines) and the pandoc command for a format (`--from org --to …`, `--standalone` unless body only, `--pdf-engine` for PDF, then `org-export-pandoc-args`), and runs it with `start-job!` from the file's directory, the text on stdin. The menu is built on `menu!`, as git's are, reopening itself with a new title when a toggle flips. The programs it runs, `pandoc` and `xdg-open`, are named in variables so the tests can put a fake pandoc in their place that records its arguments and input: CI has no pandoc, and the tests are about what imp asks of pandoc, not what pandoc writes. One more test runs the real pandoc when it is installed.

## Tasks

- [x] The `org-export` package (in `PACKAGES`) exports the buffer's text to a file beside it through pandoc in the background, for each of the seven formats (`--standalone`, `--pdf-engine` from `org-export-pdf-engine`, `org-export-pandoc-args`), and says `exported notes.html`; a missing pandoc, a failing pandoc (`*org-export*`) and a buffer with no file say so; with tests against a fake pandoc, and one against the real one when it is installed.
- [x] Exporting into a `*Org Export: FORMAT*` buffer for the text formats, and writing then opening with `xdg-open`, with tests.
- [ ] The toggles: subtree only (the heading's title becomes the document's, its children promoted), body only (no `--standalone`) and visible only (closed folds left out), with tests.
- [ ] `C-c C-e` and `SPC m e` open the two-level menu, the toggles flipping and showing in its title, and `:OrgExport FORMAT` exports with completion, with tests.
- [ ] The package's header comment says how to use it, the Org spec's known gaps no longer list export, and the owner has tried it by hand.
