---
type: Decision
status: accepted
---
# The user reference is generated from the specs

## Context

#20 asks for user documentation on the website. Each area of imp already has a spec in `docs/specs` that says what it does, its keys and options, and what it can't do yet. A reference written separately for users would say the same things a second time and fall behind as features change. Generating it means the specs have to read well for users, and the site, until now static HTML with no build step, needs one. The owner chose generating, with a small script rather than a docs framework such as mdBook, so the pages keep the site's look ([[user-docs]]).

## Decision

The docs' reference pages are generated from the specs by `tools/site-docs.py`, with pandoc, when the Pages workflow publishes the site. Only the guides are written for the docs alone.

## Consequences

- A spec is user documentation too: its Behaviour, Keys and options and Known gaps are published, so they are written for someone using imp.
- What a user is told imp can't do yet comes from Known gaps, kept with the work that would fill them.
- The site has a build step, run in the Pages workflow; generated pages aren't committed.
- Publishing needs pandoc in the Pages workflow.
