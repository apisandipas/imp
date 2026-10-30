---
type: Page
spec: "[[spec/start-screen]]"
frozen:
  docs/specs/start-screen.md: 3a63b6f3dc40
---
# Start screen

When you start imp without a file, it shows a start screen: the imp banner over a few things to do, and the version at the bottom.

## Opening something

Press the key on the right of an action, or move to it and press `<ret>`.

| Key | What it does |
|---|---|
| `r` | Pick from your recent files |
| `f` | Find a file |
| `p` | Switch to a project |
| `e` | Open the file browser |
| `/` | Search the project |
| `c` | Open your `init.scm` |
| `n` | A new, empty buffer |
| `q` | Quit |

In a small window the banner gives way to a one-line title, and comes back when there's room.

## Starting to type

Press `i` to leave the start screen and type in the empty buffer. `I`, `A`, `o` and `O` work the same way.

## Getting it back

`M-x start-screen` shows the start screen again at any time.

To begin in the empty buffer instead, turn the screen off in `init.scm`:

```scheme
(set-option! 'start-screen #f)
```

## Making it yours

All of these go in `init.scm`.

Your recent files and projects can be listed on the screen too, with the files on `1` to `9` and the projects on `a`, `s`, `d`, `g` and `h`. Name the sections you want, in the order you want them:

```scheme
(set-option! 'start-sections '(recent-files projects actions))
(set-option! 'start-recent-files 5)
```

Add your own actions, or take some away. An action is a command's name or a procedure:

```scheme
(define-start-action! "t" "Terminal" 'terminal)
(define-start-action! "o" "Agenda" 'org-agenda)
(remove-start-action! "q")
```

Change the banner to any lines you like, or `#f` for just the title:

```scheme
(set-option! 'start-banner '("welcome back"))
```

Add a section of your own with a heading and a procedure that returns its entries:

```scheme
(define-start-section! 'notes "Notes"
  (lambda ()
    (list (start-entry "1" "Inbox" (lambda () (open-file! "~/notes/inbox.org")))
          (start-entry "2" "Journal" (lambda () (open-file! "~/notes/journal.org"))))))
(set-option! 'start-sections '(actions notes))
```

If two entries have the same key, the first one gets it.

The colours come from your theme: the banner and keys in its accent colour, the labels in its text colour, and the footer dimmed. To change them, set the faces `start.title`, `start.key`, `start.label`, `start.heading` and `start.dim` with `set-face!`.

## Options

| Option | Default | What it does |
|---|---|---|
| `start-screen` | `#t` | Show the start screen when imp starts without a file |
| `start-sections` | `'(actions)` | Which sections show, in order: `actions`, `recent-files`, `projects`, or your own |
| `start-banner` | the imp banner | The banner's lines, or `#f` for a one-line title |
| `start-recent-files` | `9` | How many recent files the `recent-files` section lists, up to 9 |
| `start-projects` | `5` | How many projects the `projects` section lists, up to 5 |
| `recent-files-max` | `100` | How many recent files imp remembers |
