---
type: Page
spec: "[[spec/vim]]"
frozen:
  docs/specs/vim.md: 7a2641f5642e
---
# Vim

imp is Vim first: its keys behave as Vim's do. If something you know from Vim works differently, that's a bug. This page lists what's there.

## Moving around

All of Vim's usual motions work, with counts. A motion that can't go anywhere, such as `l` at the end of a line, fails: it cancels an operator and stops a macro.

| Kind | Keys |
|---|---|
| Characters and lines | `h j k l`, arrows, `0 ^ $ \|`, `+ - _ <ret>`, `<home> <end>` |
| Words | `w b e ge`, `W B E gE` |
| The file | `gg G`, `N%` (a count, then `%`) |
| Paragraphs and brackets | `{ }`, `%` |
| The screen | `H M L`, and `gj gk` by screen rows on wrapped lines |
| Within a line | `f F t T`, repeated with `; ,` |
| Searches | `n N * # g* g#` |
| Marks | `'x` and `` `x `` |

## Operators and text objects

An operator acts on a motion or a text object: `dw`, `ci"`, `yap`. Doubled, it acts on the line (`dd`, `>>`). Counts multiply, so `2d3w` deletes six words.

| Operator | What it does |
|---|---|
| `d` / `c` / `y` | Delete, change, yank |
| `>` / `<` | Indent, unindent |
| `gu` / `gU` / `g~` | Lower case, upper case, swap case |
| `g?` | Rot13 |
| `gc` | Comment or uncomment |

| Text object | Selects |
|---|---|
| `iw aw`, `iW aW` | A word |
| `i" a"`, `i' a'`, `` i` a` `` | Inside or around quotes, on the cursor's line |
| `i( a(`, `i[ a[`, `i{ a{`, `i< a<` | Inside or around brackets |
| `it at` | Inside or around an HTML or XML tag |
| `ip ap` | A paragraph |
| `af if`, `ac ic`, `aa ia` | A function, class or argument, where [Tree-sitter](ref-tree-sitter.md) knows the language |

## Editing

| Keys | What they do |
|---|---|
| `i a I A o O`, `gi gI` | Start inserting; counts repeat what you type |
| `x X D C s S Y` | Delete, change or yank a little |
| `p P gp gP` | Paste, with counts |
| `r R` | Replace a character, or type over text |
| `J gJ` | Join lines, with or without a space |
| `~` | Swap the case of a character |
| `C-a C-x` | Add to or subtract from the number under the cursor |
| `.` | Repeat the last change |
| `&` | Repeat the last `:s` |
| `ZZ ZQ` | Save and quit, or quit without saving |
| `C-g` | Show the file name and position |

## Visual state

`v` selects characters, `V` whole lines, and `C-v` a block. `o` and `O` move to the other end, and `gv` selects the last selection again.

Operators and text objects work on the selection, as do `I A c r J p u U ~ > <`. In a block, `$` reaches to the end of each line. `.` repeats a visual change over a region of the same size.

Press `:` from visual state to run a command on the selected lines; imp fills in `'<,'>` for you.

## Insert state

New lines keep the indentation, and `<tab>` inserts spaces when `expandtab` is on.

| Key | What it does |
|---|---|
| `C-w` / `C-u` | Delete the word, or the line, before the cursor |
| `C-h` | Delete the character before the cursor |
| `C-t` / `C-d` | Indent or unindent the line |
| `C-r` | Insert a register |
| `C-o` | Run one normal-state command |

In Replace state (`R`), `<bs>` puts back the text you typed over.

## Undo

Undo is a tree, as in Vim. If you undo and then make a change, the old changes are kept on another branch.

| Key | What it does |
|---|---|
| `u` | Undo |
| `C-r` | Redo, along the branch you last took |
| `U` | Undo the changes on the last line |
| `g-` / `g+` | Step back or forward through every state in the order you made them, across branches |

All of them take a count. `:undolist` lists the end of each branch: its change number, how many changes deep it is, and how long ago you made it.

## Searching

`/` searches forward and `?` back, highlighting matches as you type. `:noh` clears the highlight. A search works as a motion too, so `d/foo` deletes up to the next `foo`.

Searches ignore case unless you type a capital letter. Patterns use Vim's regular expression syntax.

## Registers and the clipboard

| Register | Holds |
|---|---|
| `"a` to `"z` | Yours; `"A` to `"Z` add to them |
| `"0` | The last yank |
| `"1` to `"9` | The last deletes; `"1p` then `.` steps through them |
| `"-` | The last small delete |
| `"_` | Nothing: deletes into it are lost |
| `".` `":` `"/` `"%` | The last insert, command, search and the file name |
| `"+` `"*` | The system clipboard |

To make plain `y` and `p` use the system clipboard, `:set clipboard=unnamedplus`. imp reaches the clipboard through `wl-copy`, `xclip`, `xsel` or `pbcopy`, whichever you have.

## Macros

`qa` starts recording into register `a` and `q` stops. `@a` plays it, `@@` plays the last one again, and `@:` repeats the last command line. A key that fails stops the macro.

## Marks and jumps

`ma` sets mark `a`; `'a` goes to its line and `` `a `` to its exact place. Marks move with the text as you edit. Marks `A` to `Z` work as in Vim, and so do `' . ^ [ ] < >`.

`C-o` and `C-i` go back and forward through the places you've jumped to, across buffers.

## Scrolling

| Key | What it does |
|---|---|
| `C-d` / `C-u` | Half a screen down or up |
| `C-f` / `C-b` | A screen down or up |
| `C-e` / `C-y` | One line down or up |
| `zt` / `zz` / `zb` | Put the cursor's line at the top, middle or bottom |
| `z<ret>` / `z.` / `z-` | The same, with the cursor at the line's first character |

## Ex commands

Commands take Vim's ranges: `.`, `$`, line numbers, marks, `/pattern/`, `?pattern?`, `%`, with `+` and `-` offsets. For example, `:.,+3d` deletes four lines.

| Commands | What they do |
|---|---|
| `:w [file]` `:w!` `:sav` `:e` | Save and open files |
| `:q` `:wq` `:x` `:qa` | Quit |
| `:s/old/new/` | Substitute, with the `g`, `i` and `I` flags, groups, `&` and `\r` |
| `:g/pat/cmd` `:v/pat/cmd` | Run a command on lines that match, or don't |
| `:d` `:y` `:m` `:t` `:>` `:<` `:j` `:pu` | Edit lines |
| `:sort` `:normal` `:!` `:r` | Sort, run normal keys, run a shell command, read a file in |
| `:u` `:red` `:k` `:p` `:nu` | Undo, redo, set a mark, print lines |
| `:noh` | Clear the search highlight |
| `:set` `:setlocal` | Change options |
| `:marks` `:reg` `:jumps` `:delm` | List marks, registers and jumps; delete marks |

The command line keeps a history and has Vim's editing keys, and `C-r` inserts a register. `<tab>` completes command names and their arguments: files, buffers, options, themes and help topics.

## Mappings

`:nnoremap` binds keys to other keys, as in Vim:

```vim
:nnoremap j gj
:inoremap jk <Esc>
```

| Command | Works in |
|---|---|
| `:map` / `:noremap` | Normal and visual state |
| `:nmap` / `:nnoremap` | Normal state |
| `:vmap` / `:vnoremap` | Visual state |
| `:imap` / `:inoremap` | Insert state |

The `noremap` forms run imp's own keys; the `map` forms also follow other mappings. Both sides take Vim's key notation, such as `<CR>`, `<Esc>`, `<Tab>`, `<C-x>`, `<M-x>`, `<F1>` and `<Leader>`, which is space. A count typed before a mapping applies to it.

In normal and visual state, a two-key mapping must start with a prefix such as `g`, `z` or `C-w`, or with a key that isn't bound. A longer one must start with `<Leader>`, and joins the [leader](ref-leader-and-modes.md) keys. If a mapping can't be made, `:map` says why.

In insert state, after `:inoremap jk <Esc>`, typing `j` inserts it. If `k` follows within `timeoutlen`, the `j` is taken back out and `<Esc>` runs.

`:unmap`, `:nunmap`, `:vunmap` and `:iunmap` remove a mapping. With no arguments, the map commands list your mappings.

## Not like Vim

- No Vimscript. You configure imp in Scheme, in `init.scm`.
- No mappings for operator-pending, select, command-line or terminal state, and no `<buffer>`, `<expr>`, `<script>` or `<unique>`.
- A normal-state mapping can't start with a key that already does something, such as `,w`.
- No undo by time (`:earlier`, `:later`) and no undo history kept between sessions.

## Options

Set options with `:set`, using `no`, `?`, `!` and `=` as in Vim: `:set nowrap`, `:set ts?`, `:set sw=2`.

| Option | Default | What it does |
|---|---|---|
| `tabstop` | `4` | How wide a tab is shown |
| `shiftwidth` | `4` | Columns per indent |
| `expandtab` | `#t` | Indent with spaces, not tabs |
| `autoindent` | `#t` | New lines keep the indentation |
| `smartindent` | `#f` | Indent more after an opening bracket |
| `wrapscan` | `#t` | Searches wrap around the end of the file |
| `hlsearch` | `#t` | Highlight search matches |
| `incsearch` | `#t` | Search as you type |
| `clipboard` | `""` | `unnamedplus` makes `y` and `p` use the system clipboard |
| `number` | `#f` | Show line numbers |
| `relativenumber` | `#f` | Show line numbers relative to the cursor |
| `cursorline` | `#f` | Highlight the cursor's line |
| `wrap` | `#t` | Wrap long lines |
| `linebreak` | `#f` | Wrap at word boundaries |
| `signcolumn` | `"auto"` | When to show the sign column |
| `splitbelow` | `#f` | New horizontal splits open below |
| `splitright` | `#f` | New vertical splits open on the right |
| `timeoutlen` | `1000` | Milliseconds to wait for the rest of an insert mapping |
| `cmdline-completion` | `#t` | Show the completion menu on the command line; `#f` gives back Vim's wildmenu |
