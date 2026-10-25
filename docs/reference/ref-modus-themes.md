---
type: Page
spec: "[[spec/modus-themes]]"
frozen:
  docs/specs/modus-themes.md: 211c2d3666b3
---
# Modus themes

The Modus themes from Emacs: Modus Vivendi, white on black, and Modus Operandi, black on white. They're made for the highest color contrast (WCAG AAA), so text is easy to read in either.

## Turning them on

The Modus themes are an opt-in package. Load it in `init.scm`, then load a theme:

```scheme
(use-package! 'modus-themes)
(load-theme! 'modus-vivendi)
```

Once the package is loaded, `modus-vivendi` and `modus-operandi` work like imp's other themes: switch with `:theme modus-operandi`, or press `SPC t T` and pick one. See [Look](ref-look.md).

The colors are Modus's own, for code, the status line, popups, diagnostics, diffs and git, Org, dired and terminals. Docstrings and builtins, such as built-in functions and types, get their own colors.

## Switching between them

`M-x modus-themes-toggle` switches between Modus Operandi and Modus Vivendi. From any other theme, it loads Modus Operandi.

It has no key of its own. To put it on one:

```scheme
(define-leader! "tm" 'modus-themes-toggle "modus toggle")
```

## Bold and italic

Both are off, as in Emacs. Turn them on in `init.scm`:

| Option | Default | What it does |
|---|---|---|
| `modus-themes-bold-constructs` | `#f` | Keywords, builtins, types, labels and modules in bold |
| `modus-themes-italic-constructs` | `#f` | Comments and docstrings in italic |

## Changing the colors

Modus names every color it uses, and names what each color is for, such as `keyword` or `bg-main`. Give a name a new value and everything using it follows. The value is a color, or another name:

```scheme
(set-option! 'modus-themes-common-palette-overrides
             '((keyword red) (bg-main "#111111")))
```

That makes keywords red and the background near-black, in both themes. To change only one theme, use `modus-vivendi-palette-overrides` or `modus-operandi-palette-overrides`; those win over the common list. A name Modus doesn't have is an error that names it.

Changing any of these options redraws a Modus theme that's loaded.

## Options

| Option | Default | What it does |
|---|---|---|
| `modus-themes-bold-constructs` | `#f` | Bold keywords, builtins, types, labels and modules |
| `modus-themes-italic-constructs` | `#f` | Italic comments and docstrings |
| `modus-themes-common-palette-overrides` | `'()` | Color changes for both themes |
| `modus-vivendi-palette-overrides` | `'()` | Color changes for Modus Vivendi only |
| `modus-operandi-palette-overrides` | `'()` | Color changes for Modus Operandi only |
