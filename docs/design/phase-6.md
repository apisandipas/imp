# Phase 6 design: the ecosystem

Written at the start of the phase; the Progress section records what
changed.

## Principle

These are packages, not editor features. Each one is a runtime file in
Scheme, built on the API, and ideally shows what a third-party package
can do. Rust gets only what Scheme can't do: per-buffer highlights,
read-only buffers, folds in the renderer, and a terminal emulator.

The roadmap order stands: 6.1 git, 6.2 Org, 6.3 file browser, 6.4
projects, 6.5 terminal. The shared groundwork (6.0) comes first, because
every item needs it.

## 6.0 Groundwork

**Per-buffer highlights.** Highlight layers today are global: ranges are
drawn only on the current buffer, and a pattern is drawn on every buffer.
A git status buffer needs its faces in whichever window shows it, and
nowhere else. So each buffer gets its own layers, drawn in every window
showing that buffer:
- `(buffer-highlight-add! LAYER START END FACE)`, `(buffer-highlight-clear! LAYER)`,
  `(buffer-highlight-pattern! LAYER PATTERN FACE)`, for the current
  buffer.
- Ranges don't move with edits. Generated buffers redraw them whole.
- Patterns are matched on visible lines when drawing, so they follow
  edits. That suits Org and the file browser.

**Read-only buffers.** `(set-buffer-read-only! BOOL)` and
`(buffer-read-only?)`. Primitives that change text fail on a read-only
buffer with Vim's message, "E21: Cannot make changes, 'modifiable' is
off". `:set nomodifiable` and `:set modifiable` reach the same flag. A
package lifts it around its own changes with `(with-writable thunk)`.

**Generated buffers.** In Scheme (`runtime/special.scm`):
- `(special-buffer NAME MODE)` finds or makes a buffer by name.
- `(set-buffer-contents! TEXT)` replaces the text, keeping the cursor's
  line.
- `q` closes it and returns to the previous buffer.

## 6.1 Git (Magit-like): `runtime/git.scm`

`SPC g g` or `:Git` opens `*git status*` for the current file's repository.

- **Sections**: the head (branch, upstream, ahead and behind), Untracked,
  Unstaged, Staged, Stashes and Recent commits.
- **Folding**: `<tab>` on a file shows or hides its diff, hunk by hunk.
  This is the section's own text, not editor folding.
- **Staging**: `s` stages and `u` unstages the file, the hunk or the whole
  section at the cursor. `x` discards, after asking.
- **Hunks**: a hunk is staged by feeding its patch to
  `git apply --cached`, and unstaged with `-R`.
- **Commit**: `c c` opens `*git commit*` with the staged diff shown below
  the message. `:wq` or `C-c C-c` commits; `:q!` aborts. `c a` amends.
- **Other keys**:
  - `d d` shows the diff of the thing at the cursor, and `l l` the log;
    `RET` on a commit shows it.
  - `RET` on a hunk line visits the file at that line.
  - `b b` checks out a branch (completing-read), `b c` creates one.
  - `z z` stashes and `z p` pops.
  - `f f` fetches, `F F` pulls and `P P` pushes, as jobs. Their output
    goes to `*git process*`, and the status refreshes when they finish.
  - `g` refreshes and `q` closes. `?` lists the keys.
- **Parsing**: status is parsed from
  `git status --porcelain=v2 --branch -z`, and the diffs come from
  `git diff`. Commands that are parsed run synchronously, since they are
  fast; network commands run as jobs.

Tests run against a real repository made in a temp directory.

## 6.2 Org: `runtime/org.scm`, and folding

A major mode for `.org` files covering the parts people rely on daily:
- **Faces**: headings by level, TODO keywords, dates, links, checkboxes,
  tables and markup. These are per-buffer patterns, so they follow edits.
- **Outline**: `<tab>` cycles a heading's subtree (folded, children, all),
  and `<s-tab>` cycles the whole buffer. `M-<ret>` adds a heading, `M-h`
  and `M-l` promote and demote, and `M-j` and `M-k` move a subtree.
- **TODO**: `C-c C-t` (and `t` in normal state) cycles through
  `org-todo-keywords`. `C-c C-c` toggles a checkbox, and updates `[1/3]`
  counters.
- **Links**: `[[target][text]]`. `RET` or `gx` follows one: a file link
  opens the file (with `::LINE`), and a URL goes to `xdg-open`.
- **Tables**: `<tab>` in a table row aligns the table and moves to the
  next cell. `|-` lines become rules.
- **Agenda**: `:OrgAgenda` (`SPC o a`) lists TODO items and
  SCHEDULED/DEADLINE dates from `org-agenda-files`, which defaults to the
  `.org` files under `org-directory`. `RET` jumps to an item.
- **Capture**: `SPC o c` appends a TODO to `org-default-notes-file`.

**Folding** is a core feature, because Org needs the renderer to hide
lines, and it is a Vim feature in its own right:
- A fold is a line range kept as two buffer marks, so it follows edits.
- A closed fold draws as its first line with a `··· N lines` marker.
- Vim's keys: `zf{motion}`, `zo`, `zc`, `za`, `zR`, `zM`, `zE` and `zd`.
- `j` and `k` move over a closed fold as one line, and `dd` on one
  deletes the whole fold, as in Vim.
- Rust stores the folds and draws them; Scheme decides where they are.

## 6.3 File browser (oil-style): `runtime/dired.scm`

`-` opens the current file's directory as a buffer, one name per line,
with directories marked by a trailing `/`. `RET` opens an entry and `-`
goes up. The listing is ordinary text:
- Renaming a line renames the file.
- Deleting a line deletes the file.
- A new line creates a file, or a directory if it ends in `/`.

`:w` shows the list of changes and asks before doing them.

Each line's original entry is tracked with a buffer mark. When several
marks meet on one line, the original line is the one with the highest
index, because deleting a line moves its mark to the next line. A name
that is both deleted and created, as `dd` then `p` would do, is no
change, so moving lines around never deletes a file. `g.` shows dotfiles.

## 6.4 Projects: `runtime/project.scm`

- **The root**: a project is the nearest directory above the file with a
  marker. `project-markers` defaults to `.git`, plus the LSP markers.
- **Known projects**: those visited are remembered in the state
  directory.
- **Keys**:
  - `SPC p f` finds a file in the project, and `SPC p p` switches project
    and then finds a file there.
  - `SPC p b` shows the project's buffers.
  - `SPC s p` or `:grep PATTERN` searches the project with `rg`, falling
    back to `grep -rn`.
- **Search results**: they go to `*grep*`, one `file:line:text` per line.
  `RET` jumps to a result, and `:cn` / `:cp` (or `]q` / `[q`) step through
  them, as in Vim's quickfix.

## 6.5 Terminal buffers: `src/term.rs` and `runtime/term.scm`

`:terminal [CMD]` (`SPC o t`) runs a shell in a pseudo-terminal, using the
`portable-pty` and `vt100` crates:
- **Display**: the buffer holds the scrollback and the screen as text,
  with the terminal's colors as per-buffer highlights.
- **Updates**: output arrives as an event, and the buffer is refreshed at
  most every few milliseconds.
- **Keys**: insert state is terminal state, and keys go to the program.
  `C-\ C-n` returns to normal state, where the text can be searched and
  yanked.
- **Size**: the terminal is resized to fit its window.
- **Exit**: when the program exits, the buffer says so and stays.

## Order

6.0, 6.1, 6.2 (folding first), 6.3, 6.4, 6.5. Each is committed when
`tools/check.sh` passes.

## Progress

- 6.0 Groundwork: done.
  - `buffer-highlight-add!`, `-clear!` and `-pattern!`: per-buffer layers
    in `Editor::buffer_layers`, drawn in every window showing the buffer.
  - `Buffer::read_only`, through `set-buffer-read-only!`, `:set
    [no]modifiable` and `with-writable`. Insert, delete, undo, redo and
    `:s` check it.
  - `runtime/special.scm`: `special-mode`, `special-buffer`,
    `set-buffer-contents!`, `quit-window` and `list-find`.
  - A key that a buffer's mode binds in normal state is no longer taken
    as a Vim prefix, so `q` (and `g`, `z`) can be mode keys.
- 6.1 Git: done (`runtime/git.scm`).
  - As designed, with these changes:
    - refresh is `gr`, since `g` stays Vim's prefix;
    - the status refreshes on entering it;
    - `c`, `b`, `d`, `z`, `f`, `F` and `P` open menus (`menu!` in
      special.scm), as Magit's transients do;
    - push, pull and fetch output goes to the `$` popup, not a buffer.
  - Two dispatch changes in vim.scm, so special buffers can bind any key:
    - a buffer's mode keys now come before Vim's operators and motions
      (`c`, `d`, `l`);
    - `q` returns to the buffer a special buffer was opened from.
  - Commit messages are edited in `.git/COMMIT_EDITMSG`. `ZZ` or `SPC m c`
    commits and `ZQ` or `SPC m k` cancels, not `C-c C-c`, which normal
    state treats as escape.
  - Not done: staging selected lines, rebase, merge, blame, and refreshing
    on save.
- 6.2a Folding: done.
  - `runtime/fold.scm` keeps the folds as mark pairs. The end mark is at
    the start of the line after the fold, so deleting a fold's last line
    shrinks it.
  - `set-closed-folds!` tells the renderer what to hide. It handles
    scrolling, wrap, mouse clicks, relative numbers and the
    `··· N lines` note.
  - Keys: `zf` (an operator), `zF`, `zo zO zc zC za zA zR zM zE zd zD
    zj zk`, plus `:fold`, `:foldopen[!]` and `:foldclose[!]`.
  - `j`, `k` and counts step over a closed fold, and linewise operators
    take it whole.
  - Folds open where Vim's default 'foldopen' says they should: after
    searches, marks, `%`, `{ }` and undo.
  - Differences from Vim: `h` and `l` on a fold line don't open it, and
    there is no 'foldmethod' other than manual. Org makes its own folds.
- 6.2b Org: done (`runtime/org.scm`).
  - Built as designed, with these differences:
    - `<ret>` does what the line means (link, checkbox, TODO keyword,
      table), as in Doom Emacs. `C-c C-t` and `C-c C-c` aren't usable,
      since normal state treats `C-c` as escape; `SPC m t/x/o/b` stand in.
    - `t` stays Vim's motion.
  - The faces are per-buffer patterns, so the TODO face also covers the
    leading stars (the regex crate has no lookbehind for `\zs`).
  - `M-<ret>` needed both clients to send Alt+Enter as `M-<ret>` instead of
    a plain `<ret>`.
  - The line drawing that git.scm started is now generic, in special.scm
    (`draw-begin!`, `draw-line!`, `draw-finish!`, `line-item`). The agenda
    uses it.
  - Not done: typing in a table cell doesn't keep it aligned (`<tab>` or
    `<ret>` realigns), and there are no timestamps or repeaters,
    priorities, property drawers, export, or babel.
- 6.3 File browser: done (`runtime/dired.scm`).
  - It opens with `:Explore` / `:Ex`, `SPC f d`, or `:e DIR` (through
    `*open-directory*`). Global `-` stays Vim's motion; inside the browser
    `-` goes up.
  - Tracking which line is which entry took two tries. Marks at line ends
    broke on `o`, which inserts at the end of the line above. The scheme
    that works:
    - a line that reads exactly as an entry did is that entry;
    - otherwise the entry's *sticky* mark (new in `Buffer`: text inserted
      at it goes after it) at the start of its line says which line it
      became.
  - Consequence: swapping two names reads as no change.
  - New primitives: `directory-entries`, `file-directory?`, `rename-file!`,
    `make-directory!`, `delete-path!` and `mark-set-sticky!`.
  - New buffer-locals: `write-handler` (`:w`) and `revert-handler`
    (`:e!`), for buffers that aren't files.
  - Fixed a core Vim bug the tests found: `cw` on a word's last char
    changed through the next word.
- 6.4 Projects: done (`runtime/project.scm`).
  - Roots come from `project-markers`, tried in order. Known projects are
    kept in the state directory.
  - Commands: `SPC p f/p/b` and `SPC s p` (which offers the word at the
    cursor).
  - Quickfix as in Vim:
    - `:grep` jumps to the first match and `:grep!` doesn't;
    - `:copen`, `:cn`, `:cp`, `:cfirst`, `:clast`, `:cc`, `]q` and `[q`;
    - Vim's E42 and E553 messages.
  - `grepprg` defaults to `rg --vimgrep --sort=path`. It needs an explicit
    `.`: run-shell pipes stdin, and rg then searches stdin. Without rg it
    falls back to `grep -rnI`.
  - Fixed `write_atomic` temporary names colliding between threads.
- 6.5 Terminal buffers: done (`src/term.rs`, `runtime/term.scm`).
  - Mechanics:
    - portable-pty runs the program and vt100 keeps the screen;
    - output events are coalesced into a redraw every 15 ms;
    - a redraw changes only the differing text (the CRDT's
      `common_ends`), and colors become `term:*` faces on a per-buffer
      layer.
  - History: vt100's `scrollback_len()` is its capacity, not its use. Each
    redraw moves the lines that scrolled off into a history of our own (up
    to 10,000 lines) and clears vt100's scrollback.
  - The exit is reported from a waiter thread after the output drains, so
    `[process exited N]` comes last, with the real code.
  - Keys: the TERMINAL state is a `define-state!`, so every key, `<esc>`
    and `:` included, goes to the program. `C-\ C-n` leaves; `i`, `a`, `I`
    or `A` returns.
  - Not done: mouse reporting to the program, bracketed paste, and
    resizing for windows other than the current one.

## Second polish pass (after Phase 6)

The owner asked for a polish pass before merging. Found by driving the
release binary in a pty and looking at screenshots of each screen:

- **Blank screen on a fresh account.** Steel creates `$XDG_DATA_HOME/steel`
  without its parents and prints the error to stderr, over the screen.
  The server now creates the directory first (unless `STEEL_HOME` is set).
- **`imp DIR` failed** with "Is a directory". Directories given on the
  command line (terminal and GUI clients) are now sent as `Open` messages
  once the runtime is up, so they reach the file browser.
- **Starting without a file showed an empty buffer.** `start.scm` adds
  recent files (state directory, `SPC f r`) and a start screen; `run()`
  calls `imp-start-screen` when no file was given. A buffer's mode can now
  bind digits (when no count is in progress) for its entries.
- **`:e cr<tab>` did nothing.** Tab completion on the `:` line covered
  only command names (and `:noh` stayed `:noh`). Now it completes
  arguments through `define-ex-completion!`, extends to the common prefix,
  shows the candidates in the popup (with `set-popup!`, since
  `show-popup!` makes the next key only close it) and steps through them.
  Only full command names are listed.
- **M-x listed bare names.** It shows normal-mode and leader keys beside
  each command (`completing-read` takes an optional annotate procedure).
- **`K` said "no binding"** without a language server.
- **Terminal colors** used the outer terminal's palette (and the GUI's
  fixed one); themes now give ANSI 0-15, with optional `black` and `white`
  palette entries.
- **Folds**: horizontal motions open a closed fold ('foldopen' hor).
