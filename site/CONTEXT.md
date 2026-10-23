# site

The marketing website, https://apisandipas.github.io/imp/: static HTML, CSS and JS, no build step. `.github/workflows/pages.yml` deploys it on pushes to `main` that change `site/`.

- Changes go on a `site/` branch from `main` and merge back into `main`, then `main` merges into `develop`, so the site never waits on a release and never carries unreleased code.
- Screenshots in `img/` are taken with `imp --screenshot` under a temporary `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, so no private files show.
