---
type: Page
spec: "[[spec/look]]"
frozen:
  docs/specs/look.md: 1762ab3f61ad
---
# Look

How imp looks: its colors, the status line, popups, and the window's font and spacing. All of it can be changed from `init.scm`.

## Themes

A theme sets every color in imp from a small palette. imp comes with four: `one-dark`, the default, `gruvbox-dark`, `everforest-dark` and the light `one-light`.

Switch with `:colorscheme gruvbox-dark`, or press `SPC t T` and pick one. To choose one for good, load it in `init.scm`:

```scheme
(load-theme! 'gruvbox-dark)
```

## Making your own theme

A theme can start from another one and change only some colors. Give it a name, the theme it builds on, the palette colors to change, and any faces to set on top:

```scheme
(define-theme! 'mine 'one-dark
  (hash 'bg "#1a1b26")
  (list (list "syntax.comment" "fg=#565f89")))
(load-theme! 'mine)
```

## Faces

Every color imp draws comes from a face: one for comments, one for the status line, and so on. The `normal` face is the text color and background, under everything else.

Press `SPC h F` to see the faces under the cursor. `M-x list-faces` lists every face with a sample.

Change one face with `set-face!`:

```scheme
(set-face! "syntax.comment" "fg=#ff8800 bg=blue bold")
```

In imp's terminals, the 16 ANSI colors come from the theme too.

## The status line

Each window has a status line along its bottom. It shows a colored badge for the state you're in, the file, a dot when it's modified, counts of errors and warnings, the major mode, and where you are in the file.

When a window is narrow, the values on the right go first. A long path is shortened from its start.

Set your own with a Vim-style format string:

| Item | Shows |
|---|---|
| `%m` | The state: NORMAL, INSERT and so on |
| `%f` | The file |
| `%M` | A dot when the file is modified |
| `%l` / `%c` | The line and column |
| `%L` | How many lines the file has |
| `%p` | How far through the file you are |
| `%{name}` | A named value, such as `%{major}` for the major mode, `%{title}` for a terminal's title, or `%{org-clock}` for Org's running clock |
| `%#face#` | Draw what follows in that face; `%*` goes back |
| `%=` | What follows goes on the right |

```scheme
(set-option! 'statusline " %m %f %M%=%l:%c ")
```

Windows without the focus use `statusline-inactive`.

## Popups

The which-key popup and menus open under a rule with a title, and their keys are colored. Code completion and hover help open in a box with a border at the cursor.

## The window

In the window client you can set the font, the space around the text, and how see-through the background is:

```scheme
(set-option! 'font "VictorMono Nerd Font Mono")
(set-option! 'font-size 16)
(set-option! 'window-padding 40)
(set-option! 'background-opacity 0.9)
```

`--font` and `--font-size` on the command line win over these options.

In a terminal, set `terminal-background` to `#f` to leave the theme's background unpainted. The terminal's own background shows through instead.

## Text heights

In the window client, a face can be drawn larger, such as `height=1.3`. A line is as tall as its tallest text. Org headings use this; see [Org](ref-org.md).

## Options

| Option | Default | What it does |
|---|---|---|
| `statusline` | imp's own | The status line's format |
| `statusline-inactive` | `"  %f%{title} %M%=%{major}  %l:%c   "` | The format for windows without the focus |
| `font` | `""` | The window's font family; empty uses the client's default |
| `font-size` | `0` | The font size in pixels; 0 uses the client's default |
| `window-padding` | `0` | Pixels of space around the text |
| `window-divider-width` | `0` | Pixels between side-by-side windows |
| `background-opacity` | `1` | How opaque the background is, from 0 to 1 |
| `terminal-background` | `#t` | In a terminal, paint the theme's background |
