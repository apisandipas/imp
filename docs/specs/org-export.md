---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/54
summary: "The org-export package: Org's export dispatcher (C-c C-e), turning an Org buffer into HTML, PDF, Markdown, docx, LaTeX, ODT or plain text through pandoc."
---
# Org export

The org-export package exports an Org buffer to other formats through pandoc, as Org mode's export dispatcher (`C-c C-e`) and ox-pandoc do, rather than imp having exporters of its own. It is a bundled package ([[0011-non-essential-features-are-opt-in-packages]]), loaded with `(use-package! 'org-export)`, and adds to [[org]].

## Behaviour

- `C-c C-e`, or `SPC m e`, in an Org buffer opens the export menu, a popup like Org's dispatcher. Its first key picks a format:

  | Key | Format | File |
  |---|---|---|
  | `h` | HTML | `.html` |
  | `p` | PDF, by way of LaTeX | `.pdf` |
  | `m` | Markdown, GitHub-flavoured | `.md` |
  | `d` | Word | `.docx` |
  | `l` | LaTeX | `.tex` |
  | `o` | OpenDocument | `.odt` |
  | `t` | Plain text | `.txt` |

- The second key says what to do with it, as in Org's dispatcher.
  - The format's own key again (`h h`) writes the file.
  - `o` (`h o`) writes the file, then opens it with `xdg-open`.
  - Its capital (`h H`) writes the output into a buffer, `*Org Export: HTML*`, instead of a file, and shows it. PDF, Word and OpenDocument aren't text and have no buffer entry.
- The file goes beside the Org file, with its extension changed: `notes.org` becomes `notes.html`, replacing one already there. When it is written the message line says so (`exported notes.html`).
- The buffer's text is exported, unsaved edits included. pandoc runs in the Org file's directory, so relative links and images resolve as they do from the file.
- A buffer visiting no file can still be exported to a buffer; exporting it to a file says it has no file.
- The menu has three toggles, as Org's has. Each is off when the menu opens, flips when its key is pressed, and shows in the menu's title while it is on. They apply to the export the next keys run.
  - `C-s`, subtree only: only the heading at the cursor and what is under it. Its title becomes the document's title.
  - `C-b`, body only: no surrounding document (no `<html>` and `<head>`, no LaTeX preamble), just the body, for pasting into another document.
  - `C-v`, visible only: text inside closed folds is left out.
- Without body only, the output is a whole document (`pandoc --standalone`), its title from `#+TITLE:` as pandoc reads it.
- pandoc runs in the background; editing carries on while it works.
- PDF is made with the LaTeX engine in `org-export-pdf-engine`, `xelatex` by default since it copes with Unicode. Any engine pandoc takes works (`lualatex`, `tectonic`, `typst`, `weasyprint`).
- `org-export-pandoc-args` is a string added to every pandoc run, as `--toc` or `--css style.css`. It is empty by default.
- When pandoc isn't installed, the message line says `org-export needs pandoc` and nothing runs.
- When pandoc fails (a missing LaTeX engine, a bad template), the message line says `export failed: see *org-export*`. pandoc's error output is in the `*org-export*` buffer, and no file is opened.
- `:OrgExport FORMAT` exports to a file without the menu, the format one of `html`, `pdf`, `markdown`, `docx`, `latex`, `odt` or `text`, with completion.

## Keys and options

`C-c C-e`, `SPC m e`, `:OrgExport`, the options `org-export-pdf-engine` and `org-export-pandoc-args`.

## Out of scope

- Exporters written in imp; whatever pandoc does with Org's syntax is what you get.
- Org's publishing (`P`, `org-publish`) and inserting an export options template (`#`).
- An async toggle (`C-a`): export always runs in the background.
- Settings for one format only (a CSS file only for HTML); `org-export-pandoc-args` goes to every format.
- Org's `#+OPTIONS:` and `#+EXPORT_FILE_NAME:` beyond what pandoc reads itself.
- Exporting other modes' buffers (Markdown to HTML).

## Known gaps
