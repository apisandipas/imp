---
name: docs-page
description: Write or refresh a page of imp's user reference (docs/reference/ref-NAME.md) in plain English from its spec (docs/specs/NAME.md). Use when a spec has no page, when lore check or tools/site-docs.py --check says a page's spec has changed, or when the user asks to write, rewrite or improve a docs page.
---

# docs-page

The specs in `docs/specs` say exactly what imp does, for contributors and tests. A reference page says the same things for someone learning imp, in plain English. The website builds its docs from these pages (`tools/site-docs.py`, decision 0018). The spec stays the source of truth; the page must never claim more than the spec says.

## Who reads it

Someone who has installed imp and wants to use one area of it. They know a little Vim, maybe some Emacs. They haven't read the code, the decisions or the other specs. They want to know what to press and what happens.

## Steps

1. **Read the spec**: `docs/specs/NAME.md`, all of it. Run `lore show docs/specs/NAME.md` for its links. Where a statement is unclear, read the code its `anchors:` name (keys are bound in `runtime/*.scm` or `packages/*/`). Don't guess a key or a default; leave it out if you can't confirm it.
2. **If the page exists**, read it and the spec's changes since it was written (`git log -p` on the spec since the page's last commit). Change only what the spec changed, and keep the rest.
3. **Write `docs/reference/ref-NAME.md`** in the shape below.
4. **Stamp it**: `tools/site-docs.py --stamp NAME` records the spec version the page now matches.
5. **Build and look**: `tools/site-docs.py`, then open `site/docs/ref-NAME.html`. On a headless machine: `google-chrome --headless=new --window-size=1400,2000 --screenshot=OUT.png file://$PWD/site/docs/ref-NAME.html`, and read the PNG. Check that no section is a wall of text.
6. **Check**: `tools/site-docs.py --check` and `lore check`.

## Shape

```markdown
---
type: Page
spec: "[[spec/NAME]]"
---
# Title

One or two sentences: what this area is for, in the reader's terms.

## Not yet in imp

- One line per gap from the spec's Known gaps, with its issue as [#59](https://github.com/apisandipas/imp/issues/59).

## A task, named as the reader would

Short paragraphs, then a table of keys.

## Options

| Option | Default | What it does |
|---|---|---|
```

- The title is the spec's title, unless a plainer word exists (dired's is "File browser").
- `## Not yet in imp` comes first after the opening, and only when the spec has Known gaps. It becomes a notice at the top of the page.
- Then one section per thing a user does, ordered from most to least common: "Folding headings", "Dates and the calendar", "The agenda". Not "Behaviour".
- End with `## Options` when the area has any, and `## Commands` for ex commands when that helps.
- Leave `frozen:` to `--stamp`.

## How it reads

- Plain English. Short sentences, one idea each. A paragraph is at most three sentences.
- Say what to press, then what happens: "Press `<tab>` on a heading to fold it."
- Keys go in tables: `| Key | What it does |`. Use a table as soon as there are three or more keys. Write keys as imp shows them: `SPC m s`, `C-c C-s`, `<tab>`.
- Use a short example (an Org snippet, a line of `init.scm`) where it says more than a sentence.
- No internals: no Rust, no "primitive", no function names unless the reader calls them in `init.scm`.
- No links to decisions, efforts or code. Link other pages as `[Org export](ref-org-export.md)` and guides as `[Configuring init.scm](configuring.md)`.
- Don't hedge and don't sell. Don't promise what the spec puts out of scope; mention an out-of-scope item only when a reader would expect it ("No word diff: changes are marked per line").
- Everything on the page must be true by the spec. When in doubt, leave it out.
