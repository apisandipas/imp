---
type: Decision
status: accepted
supersedes: ["[[decision/0017-the-user-reference-is-generated-from-the-specs]]"]
---

# User reference pages are written from the specs and checked for drift

## Context

[[0017-the-user-reference-is-generated-from-the-specs]] published each spec's sections as its reference page. Built that way, the pages were walls of text: a spec is precise on purpose, every sentence a claim a test can hold the code to, and that is hard going for someone learning imp. Rewriting the specs for users would cost them that precision. Calling a model from the Pages workflow at publish time would need an API key and publish text nobody reviewed. The owner chose to have the plain-English pages written once and reviewed, as a skill says ([[user-docs]]).

## Decision

Each reference page is written in plain English from its spec, by the `docs-page` skill, and kept in `docs/reference/NAME.md`. The page records the hash of the spec it was written from, and `tools/site-docs.py --check` fails when the spec has changed since, so the page is rewritten with it.

## Consequences

- Specs stay written for contributors and tests; pages are written for users. Neither has to serve both.
- A spec change that alters what users see means rewriting its page in the same change, or the check fails.
- The skill, not the generator, says how a page reads: its structure, tone and key tables.
- The site still has a build step, run in the Pages workflow; generated HTML isn't committed.
