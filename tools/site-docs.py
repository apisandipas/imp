#!/usr/bin/env python3
"""Builds the website's docs section, site/docs/, with pandoc: the guides
in docs/guide/*.md, and a reference page for each spec in docs/specs (see
lore:0017). The Pages workflow runs it before publishing; site/docs/ isn't
committed.

    tools/site-docs.py [OUT]     (OUT defaults to site/docs)
"""

import html
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPECS = ROOT / "docs" / "specs"
GUIDES = ROOT / "docs" / "guide"
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
    ("Editing", ["vim", "emacs-state", "leader-and-modes", "mouse", "look", "start-screen"]),
    ("Files and windows", ["files", "buffers-and-windows", "projects", "dired", "folding", "terminals"]),
    ("Code", ["completion", "completion-at-point", "lsp", "tree-sitter", "dap"]),
    ("Git and Org", ["git", "git-blame", "git-gutter", "org", "org-export"]),
    ("Extending imp", ["live-scheme-and-help", "packages", "kdl-config", "wasm-plugins",
                       "daemon", "shared-buffers", "claude", "mcp"]),
]
# Specs that aren't about using imp.
SKIP = {"user-docs"}

# Reference pages are named after their spec; a guide's name can't clash.
REF_PREFIX = "ref-"


def read_note(path):
    """A note's (frontmatter dict, title, {section: text}, intro)."""
    text = path.read_text()
    meta = {}
    if text.startswith("---\n"):
        end = text.index("\n---\n", 4)
        for line in text[4:end].splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                meta[key.strip()] = value.strip().strip('"')
        text = text[end + 5:]
    title_match = re.search(r"^# (.+)$", text, re.M)
    title = title_match.group(1).strip() if title_match else path.stem
    body = text[title_match.end():] if title_match else text
    parts = re.split(r"^## (.+)$", body, flags=re.M)
    intro = parts[0].strip()
    sections = {parts[i].strip(): parts[i + 1].strip() for i in range(1, len(parts), 2)}
    return meta, title, sections, intro


def note_titles():
    """The title of every note a [[link]] can name, by its file stem."""
    titles = {}
    for path in (ROOT / "docs").rglob("*.md"):
        _, title, _, _ = read_note(path)
        titles[path.stem] = title
    return titles


def resolve_links(markdown, spec_pages, titles):
    """[[name]] links: to a spec's page when they name one, else the
    note's title as plain text (decisions and efforts stay in the repo)."""

    def link(match):
        target = match.group(1).split("|")[0].strip()
        name = target.split("/")[-1]
        if name in spec_pages:
            return f"[{titles.get(name, name)}]({REF_PREFIX}{name}.html)"
        title = titles.get(name, name)
        # A decision's title is a sentence; a plain mention reads better.
        return title[0].lower() + title[1:] if re.match(r"^\d{4}-", name) else title

    return re.sub(r"\[\[([^\]]+)\]\]", link, markdown)


def to_html(markdown):
    """`markdown` as an HTML fragment, by pandoc."""
    return subprocess.run(
        ["pandoc", "--from", "gfm", "--to", "html"],
        input=markdown, capture_output=True, text=True, check=True,
    ).stdout


def sidebar(current, spec_titles):
    """The list of every page, `current` marked."""

    def item(href, title):
        mark = ' aria-current="page"' if href == current else ""
        return f'<li><a href="{href}"{mark}>{html.escape(title)}</a></li>'

    out = ['<nav class="docs-nav" id="pages" aria-label="Docs">',
           '<p class="docs-nav-head">Guides</p><ul>', item("index.html", "Overview")]
    out += [item(f"{stem}.html", title) for stem, title in GUIDE_PAGES if (GUIDES / f"{stem}.md").exists()]
    out.append("</ul>")
    for group, stems in GROUPS:
        out.append(f'<p class="docs-nav-head">{html.escape(group)}</p><ul>')
        out += [item(f"{REF_PREFIX}{stem}.html", spec_titles[stem]) for stem in stems]
        out.append("</ul>")
    out.append("</nav>")
    return "\n".join(out)


def page(title, content, current, spec_titles):
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
  <header class="nav">
    <div class="wrap nav-inner">
      <a class="brand" href="../index.html" aria-label="imp home">imp<span class="brand-cursor" aria-hidden="true"></span></a>
      <nav aria-label="Main">
        <ul class="nav-links">
          <li><a href="index.html" aria-current="true">Docs</a></li>
          <li><a href="https://github.com/apisandipas/imp" class="nav-gh">GitHub</a></li>
        </ul>
      </nav>
      <a class="btn btn-small" href="../index.html#install">Get imp</a>
    </div>
  </header>
  <div class="wrap docs-layout">
    <main id="main" class="docs-main">
      <a class="docs-jump" href="#pages">All pages</a>
      <article class="prose">
{content}
      </article>
    </main>
{sidebar(current, spec_titles)}
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


def gaps_notice(gaps, spec_pages, titles):
    """Known gaps as a notice: what this area can't do yet."""
    if not gaps.strip():
        return ""
    items = to_html(resolve_links(gaps, spec_pages, titles))
    return f'<aside class="notice" aria-label="Not yet in imp">\n<p class="notice-head">Not yet in imp</p>\n{items}</aside>\n'


def spec_page(stem, spec_pages, titles):
    """The reference page for spec `stem`: (title, HTML content)."""
    meta, title, sections, _ = read_note(SPECS / f"{stem}.md")
    parts = [f"<h1>{html.escape(title)}</h1>"]
    if meta.get("summary"):
        parts.append(f'<p class="lede">{html.escape(meta["summary"])}</p>')
    parts.append(gaps_notice(sections.get("Known gaps", ""), spec_pages, titles))
    for heading, shown in [("Behaviour", "How it works"), ("Keys and options", "Keys and options")]:
        if sections.get(heading):
            parts.append(f"<h2>{shown}</h2>")
            parts.append(to_html(resolve_links(sections[heading], spec_pages, titles)))
    return title, "\n".join(parts)


def index_content(spec_titles):
    """The docs' front page: docs/guide/index.md, then the reference."""
    intro = GUIDES / "index.md"
    parts = [to_html(intro.read_text()) if intro.exists() else "<h1>imp docs</h1>"]
    parts.append("<h2>Reference</h2>")
    for group, stems in GROUPS:
        parts.append(f"<h3>{html.escape(group)}</h3><ul>")
        parts += [f'<li><a href="{REF_PREFIX}{s}.html">{html.escape(spec_titles[s])}</a></li>' for s in stems]
        parts.append("</ul>")
    return "\n".join(parts)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "site" / "docs"
    stems = {p.stem for p in SPECS.glob("*.md")} - SKIP
    grouped = [s for _, ss in GROUPS for s in ss]
    missing, unknown = stems - set(grouped), set(grouped) - stems
    if missing or unknown or len(grouped) != len(set(grouped)):
        sys.exit(f"site-docs: put each spec in one group of GROUPS: "
                 f"missing {sorted(missing)}, unknown {sorted(unknown)}")
    titles = note_titles()
    spec_titles = {s: titles[s] for s in stems}
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.html"):
        old.unlink()
    (out / "index.html").write_text(page("Docs", index_content(spec_titles), "index.html", spec_titles))
    for stem, title in GUIDE_PAGES:
        source = GUIDES / f"{stem}.md"
        if source.exists():
            content = to_html(resolve_links(source.read_text(), stems, titles))
            (out / f"{stem}.html").write_text(page(title, content, f"{stem}.html", spec_titles))
    for stem in grouped:
        title, content = spec_page(stem, stems, titles)
        name = f"{REF_PREFIX}{stem}.html"
        (out / name).write_text(page(title, content, name, spec_titles))
    print(f"site-docs: {len(grouped) + 1} pages in {out}")


if __name__ == "__main__":
    main()
