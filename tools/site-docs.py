#!/usr/bin/env python3
"""Builds the website's docs section, site/docs/, with pandoc: the guides
in docs/guide/*.md, and the reference pages in docs/reference/ref-NAME.md,
each written in plain English from the spec docs/specs/NAME.md (see
lore:0018). The Pages workflow runs it before publishing; site/docs/ isn't
committed.

    tools/site-docs.py [OUT]       build into OUT (default site/docs)
    tools/site-docs.py --check     specs without pages, pages without
                                   specs, and pages whose spec has changed
    tools/site-docs.py --stamp NAME  record that ref-NAME.md is up to date
                                   with its spec (lore freeze)

A page is a lore note of type Page, frozen against its spec, so lore check
also says when a spec has moved on. Links between pages are written as
[text](ref-NAME.md) and [text](GUIDE.md).
"""

import html
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPECS = ROOT / "docs" / "specs"
GUIDES = ROOT / "docs" / "guide"
PAGES = ROOT / "docs" / "reference"
ISSUES = "https://github.com/apisandipas/imp/issues"

# The guides, in reading order: (file stem, title).
GUIDE_PAGES = [
    ("first-steps", "Install and first steps"),
    ("configuring", "Configuring init.scm"),
    ("packages", "Packages"),
    ("coming-from", "Coming from Emacs or Vim"),
]

# The reference, grouped by area: every spec but the ones in SKIP is in
# exactly one group, or the build fails, so a new spec can't go missing.
GROUPS = [
    ("Editing", ["vim", "emacs-state", "auto-pairs", "move-lines", "leader-and-modes", "commands", "mouse", "posframe",
                 "look", "modus-themes", "olivetti", "start-screen"]),
    ("Files and windows", ["files", "buffers-and-windows", "projects", "go-to-file", "dired", "file-tree", "folding", "terminals"]),
    ("Code", ["completion", "completion-by-use", "completion-at-point", "lsp", "tree-sitter", "dap"]),
    ("Git and Org", ["git", "git-blame", "git-gutter", "org", "org-agenda", "org-export"]),
    ("Extending imp", ["live-scheme-and-help", "packages", "overlays", "kdl-config", "wasm-plugins",
                       "daemon", "shared-buffers", "claude", "mcp", "showkeys"]),
]
# Specs that aren't about using imp.
SKIP = {"user-docs"}

# Reference pages are named after their spec; a guide's name can't clash.
REF_PREFIX = "ref-"


def read_page(path):
    """A page's (title, lede markdown, [(heading, markdown)]), frontmatter
    dropped."""
    text = path.read_text()
    if text.startswith("---\n"):
        text = text[text.index("\n---\n", 4) + 5:]
    match = re.search(r"^# (.+)$", text, re.M)
    title = match.group(1).strip() if match else path.stem
    parts = re.split(r"^## (.+)$", text[match.end():] if match else text, flags=re.M)
    sections = [(parts[i].strip(), parts[i + 1].strip()) for i in range(1, len(parts), 2)]
    return title, parts[0].strip(), sections


def page_links(markdown):
    """Links to pages and guides, written to their .md files, made to go
    to the .html pages built from them."""
    return re.sub(r"\]\(([a-z0-9-]+)\.md(#[^)]*)?\)", lambda m: f"]({m.group(1)}.html{m.group(2) or ''})", markdown)


def to_html(markdown):
    """`markdown` as an HTML fragment, by pandoc."""
    return subprocess.run(
        ["pandoc", "--from", "gfm", "--to", "html"],
        input=page_links(markdown), capture_output=True, text=True, check=True,
    ).stdout


def site_nav():
    """The home page's navigation bar, so the docs share it: its links made
    to go from site/docs/ to the home page, and Docs marked current."""
    home = (ROOT / "site" / "index.html").read_text()
    nav = re.search(r'^ *<header class="nav">.*?</header>', home, re.S | re.M).group(0)
    nav = nav.replace('href="#top"', 'href="../index.html"')
    nav = re.sub(r'href="#([^"]+)"', r'href="../index.html#\1"', nav)
    return nav.replace('href="docs/"', 'href="index.html" aria-current="true"')


def sidebar(current, titles):
    """The list of every page, `current` marked."""

    def item(href, title):
        mark = ' aria-current="page"' if href == current else ""
        return f'<li><a href="{href}"{mark}>{html.escape(title)}</a></li>'

    out = ['<nav class="docs-nav" id="pages" aria-label="Docs">',
           '<p class="docs-nav-head">Guides</p><ul>', item("index.html", "Overview")]
    out += [item(f"{stem}.html", title) for stem, title in GUIDE_PAGES if (GUIDES / f"{stem}.md").exists()]
    out.append("</ul>")
    for group, stems in GROUPS:
        if not any(stem in titles for stem in stems):
            continue
        out.append(f'<p class="docs-nav-head">{html.escape(group)}</p><ul>')
        out += [item(f"{REF_PREFIX}{stem}.html", titles[stem]) for stem in stems if stem in titles]
        out.append("</ul>")
    out.append("</nav>")
    return "\n".join(out)


def page(title, content, current, titles):
    """A whole docs page in the site's look."""
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)} · imp docs</title>
  <meta name="theme-color" content="#1b2023">
  <link rel="icon" href="../favicon.svg" type="image/svg+xml">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="../style.css">
</head>
<body class="docs">
  <a class="skip" href="#main">Skip to content</a>
{site_nav()}
  <div class="wrap docs-layout">
    <main id="main" class="docs-main">
      <a class="docs-jump" href="#pages">All pages</a>
      <article class="prose">
{content}
      </article>
    </main>
{sidebar(current, titles)}
  </div>
  <footer class="footer">
    <div class="wrap footer-inner">
      <span class="brand brand-small">imp<span class="brand-cursor" aria-hidden="true"></span></span>
      <p>Free software under the GPL-3.0-or-later.</p>
      <ul>
        <li><a href="https://github.com/apisandipas/imp">Source</a></li>
        <li><a href="https://github.com/apisandipas/imp/releases">Releases</a></li>
        <li><a href="{ISSUES}">Issues</a></li>
      </ul>
    </div>
  </footer>
</body>
</html>
"""


def reference_content(path):
    """A reference page's HTML: its title, the paragraph under it as the
    lede, "Not yet in imp" as a notice, then its sections."""
    title, lede, sections = read_page(path)
    parts = [f"<h1>{html.escape(title)}</h1>"]
    if lede:
        parts.append(to_html(lede).replace("<p>", '<p class="lede">', 1))
    for heading, body in sections:
        if heading == "Not yet in imp":
            parts.insert(2, f'<aside class="notice" aria-label="Not yet in imp">\n'
                            f'<p class="notice-head">Not yet in imp</p>\n{to_html(body)}</aside>')
        else:
            parts.append(f"<h2>{html.escape(heading)}</h2>\n{to_html(body)}")
    return title, "\n".join(parts)


def index_content(titles):
    """The docs' front page: docs/guide/index.md, then the reference."""
    intro = GUIDES / "index.md"
    parts = [to_html(intro.read_text()) if intro.exists() else "<h1>imp docs</h1>"]
    parts.append("<h2>Reference</h2>")
    for group, stems in GROUPS:
        if not any(s in titles for s in stems):
            continue
        parts.append(f"<h3>{html.escape(group)}</h3><ul>")
        parts += [f'<li><a href="{REF_PREFIX}{s}.html">{html.escape(titles[s])}</a></li>'
                  for s in stems if s in titles]
        parts.append("</ul>")
    return "\n".join(parts)


def problems():
    """What --check reports: the grouping, specs without pages, pages
    without specs, and pages whose spec changed since they were written."""
    specs = {p.stem for p in SPECS.glob("*.md")} - SKIP
    grouped = [s for _, ss in GROUPS for s in ss]
    found = []
    for s in sorted(specs - set(grouped)):
        found.append(f"docs/specs/{s}.md: in no group of GROUPS in tools/site-docs.py")
    for s in sorted(set(grouped) - specs):
        found.append(f"tools/site-docs.py: GROUPS names {s}, which has no spec")
    for s in sorted(specs):
        if not (PAGES / f"{REF_PREFIX}{s}.md").exists():
            found.append(f"docs/specs/{s}.md: no page; write docs/reference/{REF_PREFIX}{s}.md (docs-page skill)")
    for p in sorted(PAGES.glob("*.md")):
        if p.stem[len(REF_PREFIX):] not in specs:
            found.append(f"docs/reference/{p.name}: no spec docs/specs/{p.stem[len(REF_PREFIX):]}.md")
    # Drift is lore's to find; where lore isn't installed (CI's check jobs),
    # CI's docs job, which has it, looks.
    try:
        lore = subprocess.run(["lore", "check"], cwd=ROOT, capture_output=True, text=True)
        found += [line for line in lore.stdout.splitlines() if line.startswith("docs/reference/")]
    except FileNotFoundError:
        pass
    return found


def build(out):
    """Writes every page into `out`."""
    stems = [s for _, ss in GROUPS for s in ss]
    titles = {s: read_page(PAGES / f"{REF_PREFIX}{s}.md")[0]
              for s in stems if (PAGES / f"{REF_PREFIX}{s}.md").exists()}
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.html"):
        old.unlink()
    (out / "index.html").write_text(page("Docs", index_content(titles), "index.html", titles))
    for stem, title in GUIDE_PAGES:
        source = GUIDES / f"{stem}.md"
        if source.exists():
            (out / f"{stem}.html").write_text(page(title, to_html(source.read_text()), f"{stem}.html", titles))
    for stem in titles:
        name = f"{REF_PREFIX}{stem}.html"
        title, content = reference_content(PAGES / f"{REF_PREFIX}{stem}.md")
        (out / name).write_text(page(title, content, name, titles))
    print(f"site-docs: {len(titles) + 1} pages in {out}; {len(stems) - len(titles)} reference pages not written yet")


def main():
    args = sys.argv[1:]
    if args[:1] == ["--check"]:
        found = problems()
        print("\n".join(found) or "site-docs: every spec has an up-to-date page")
        sys.exit(1 if found else 0)
    if args[:1] == ["--stamp"] and len(args) == 2:
        sys.exit(subprocess.run(["lore", "freeze", f"docs/reference/{REF_PREFIX}{args[1]}.md"], cwd=ROOT).returncode)
    build(Path(args[0]) if args else ROOT / "site" / "docs")


if __name__ == "__main__":
    main()
