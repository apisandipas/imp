# site

The marketing website, https://apisandipas.github.io/imp/: static HTML, CSS and JS. `.github/workflows/pages.yml` deploys it on pushes to `main` that change `site/` or the docs.

- The docs section, `site/docs/`, is built, not written: `tools/site-docs.py` makes it from `docs/guide/*.md` and the reference pages in `docs/reference/` ([[0018-user-reference-pages-are-written-from-the-specs-and-checked]]), and the Pages workflow runs it before deploying. It's ignored by git; its styles are the Docs part of `style.css`. The docs describe a release, so they're written on `develop` and go live when a release merges into `main`.
- Changes go on a `site/` branch from `main` and merge back into `main`, then `main` merges into `develop`, so the site never waits on a release and never carries unreleased code.
- Screenshots in `img/` are taken with `imp --screenshot` under a temporary `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, so no private files show.
