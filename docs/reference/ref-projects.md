---
type: Page
spec: "[[spec/projects]]"
frozen:
  docs/specs/projects.md: fac9a61f6afa
---
# Projects

A project is the directory your file belongs to, such as a git repository. imp finds it for you, so you can open its files, switch between its buffers, and search all of it.

## Which directory is the project

imp looks up from the file's directory for one holding a marker: `.git`, `.hg`, `.jj` or `.project`. The nearest directory with one is the project. The markers are tried in order, so a git repository wins over a `.project` inside it.

To use other markers, set `project-markers`:

```scheme
(set-option! 'project-markers '(".git" "Cargo.toml"))
```

imp remembers the projects you open files in, between sessions.

## Opening files and buffers

| Key | What it does |
|---|---|
| `SPC p f` | Find a file in the project |
| `SPC p p` | Switch to another project you've used, then find a file in it |
| `SPC p b` | Switch to one of the project's buffers |

## Searching the project

Press `SPC s p` to search the whole project. It starts from the word under the cursor, so press `<ret>` to search for that, or type something else. The matches open in `*grep*` along the bottom of the screen.

`:grep PATTERN` searches too, and jumps to the first match. `:grep! PATTERN` doesn't jump. imp searches with `rg` if you have it, and with `grep` if you don't.

## Going through the matches

The matches make a quickfix list, as in Vim. In `*grep*`, press `<ret>` on a match to go to it.

| Key or command | What it does |
|---|---|
| `:copen` | Show the list in `*grep*` |
| `]q` or `:cn` | Next match |
| `[q` or `:cp` | Previous match |
| `:cfirst` / `:clast` | First or last match |
| `:cc N` | Match number N |

Past either end, imp says `E553: No more items`. With no list, it says `E42: No Errors`, as Vim does.

## Options

| Option | Default | What it does |
|---|---|---|
| `project-markers` | `'(".git" ".hg" ".jj" ".project")` | The files or directories that mark a project's top, tried in order |
| `grepprg` | `""` | The command that searches; empty means `rg`, or `grep` without it |
