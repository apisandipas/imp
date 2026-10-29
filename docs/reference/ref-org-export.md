---
type: Page
spec: "[[spec/org-export]]"
frozen:
  docs/specs/org-export.md: d011ff8473b5
---
# Org export

Org export turns an Org file into HTML, PDF, Markdown, Word, LaTeX, OpenDocument or plain text. It works like Org mode's export menu and adds to [Org](ref-org.md). pandoc does the converting, so what pandoc makes of your Org file is what you get.

## Turning it on

Org export is an opt-in package. Load it near the top of your `init.scm`:

```scheme
(use-package! 'org-export)
```

You also need pandoc installed. Without it, exporting says `org-export needs pandoc` and does nothing. For PDF you need a LaTeX engine too, `xelatex` by default.

## Exporting a file

In an Org buffer, press `C-c C-e` or `SPC m e` to open the export menu. The first key picks the format:

| Key | Format | File |
|---|---|---|
| `h` | HTML | `.html` |
| `p` | PDF, made with LaTeX | `.pdf` |
| `m` | Markdown, GitHub-flavoured | `.md` |
| `d` | Word | `.docx` |
| `l` | LaTeX | `.tex` |
| `o` | OpenDocument | `.odt` |
| `t` | Plain text | `.txt` |

The second key says what to do with it. Using HTML as the example:

| Keys | What they do |
|---|---|
| `h h` | Write the file |
| `h o` | Write the file, then open it in its usual app |
| `h H` | Show the output in a buffer, `*Org Export: HTML*`, instead of a file |

For OpenDocument, whose key is already `o`, press `o O` to write and open the file. PDF, Word and OpenDocument aren't text, so they can't go in a buffer.

## Where the file goes

The file goes beside the Org file, with its extension changed: `notes.org` becomes `notes.html`. A file of that name already there is replaced. When it's done, the message line says `exported notes.html`.

What's in the buffer is exported, unsaved edits included. Relative links and images work as they do from the Org file. A buffer with no file can only be exported to a buffer.

Exporting runs in the background, so you can keep editing while it works.

## Exporting part of a file

Before picking the format, you can turn on any of three toggles. Each starts off, and shows in the menu's title while it's on.

| Key | Toggle | What it does |
|---|---|---|
| `C-s` | Subtree only | Export just the heading under the cursor and what's under it. The heading becomes the document's title |
| `C-b` | Body only | Leave out the surrounding document, such as HTML's `<head>` or LaTeX's preamble, for pasting into another document |
| `C-v` | Visible only | Leave out text inside closed folds |

For example, `C-s h H` shows the current heading as HTML in a buffer.

Without body only, you get a whole document. Its title comes from the file's `#+TITLE:` line.

## If export fails

If pandoc fails, for example because the LaTeX engine is missing, the message line says `export failed: see *org-export*`. pandoc's error output is in the `*org-export*` buffer, and no file is opened.

## Without the menu

Type `:org-export` and a format to write the file straight away, without the menu. The format is one of `html`, `pdf`, `markdown`, `docx`, `latex`, `odt` or `text`. Press `<tab>` to complete it.

```
:org-export html
```

## Options

To add a table of contents to every export:

```scheme
(set-option! 'org-export-pandoc-args "--toc")
```

| Option | Default | What it does |
|---|---|---|
| `org-export-pdf-engine` | `"xelatex"` | The engine that makes PDFs; any pandoc takes works, such as `lualatex`, `tectonic`, `typst` or `weasyprint` |
| `org-export-pandoc-args` | `""` | Extra arguments for every pandoc run and every format, such as `"--toc"` or `"--css style.css"` |
