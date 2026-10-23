---
status: accepted
summary: "Vim's normal, insert, visual and command-line behavior, matched against real Vim."
anchors: [runtime/vim.scm, crates/imp-server/src/search.rs, crates/imp-server/src/scan.rs, crates/imp-server/tests/vim.rs]
---
# Vim

imp is Vim-first ([[0006-vim-by-default-in-the-core]]). Everything here behaves as Vim does; where it doesn't, that's a bug.

## Behaviour

- **Motions**: `h j k l w b e ge W B E gE 0 ^ $ | + - _ <ret> gg G N% { } % H M L f F t T ; , n N * # g* g#`, arrows, `<home> <end>`, marks `'x` and `` `x``, `gj gk` by screen rows. Vim's rules for exclusive motions and the `dw`/`cw` special cases. A motion can fail: that cancels an operator, stops a macro, and lets `h j k l` fail at edges.
- **Text objects**: `iw aw iW aW`, quotes (on the cursor's line only), every bracket kind, `it at`, `ip ap`; tree-sitter adds `af if ac ic aa ia` ([[tree-sitter]]). `aw` takes trailing white space, else leading; `i{` on braces on their own lines is linewise over the inner lines.
- **Operators**: `d c y > < gu gU g~ g? gc`, doubled forms, counts that multiply. A linewise range is always whole lines; only `d` knows the final-newline case.
- **Commands**: `x X D C s S Y p P gp gP r R J gJ ~ C-a C-x u C-r U . & ZZ ZQ C-g i a I A o O gi gI`, counts on inserts and pastes.
- **Visual**: `v V C-v`, `o O gv`, operators and text objects, `I A c r J p u U ~ > <`, block `$`, and `.` over the same size of region. `:` from visual uses the `<` and `>` marks.
- **Insert**: autoindent and smartindent, expandtab-aware `<tab>`, `C-w C-u C-h C-t C-d C-r C-o`, `<del> <home> <end> <up> <down>`; Replace mode restores on `<bs>`.
- **Search**: `/ ? n N * #`, incremental and highlighted (`:noh`), as a motion (`d/foo`), smartcase, Vim regex syntax translated to the `regex` crate.
- **Registers**: `"a-z "A-Z "0-9 "- "_ ". ": "/ "% "+ "*`, `clipboard=unnamedplus`, `"1p..`. The system clipboard goes through `wl-copy`, `xclip`, `xsel` or `pbcopy`.
- **Macros**: `q @ @@ @:`; a failing key stops a macro. Keys are stored as text in Vim notation.
- **Marks and jumps**: `a-zA-Z ' . ^ [ ] < >` (marks live in the buffer and move with edits), the jump list `C-o C-i` across buffers.
- **Scrolling**: `C-d C-u C-f C-b C-e C-y zt zz zb z<ret> z. z-`.
- **Ex**: ranges (`. $ N 'x /pat/ ?pat? %` and offsets); `:w [file] :w! :sav :q :wq :x :qa :e`; `:s` with `g i I`, groups, `&`, `\r`; `:d :y :m :t :> :< :j :pu :k :p :nu :sort :normal :g :v :! :r :u :red :noh :set :setlocal :marks :reg :jumps :delm`; command-line history and editing keys, `C-r`. `<tab>` completes command names and their arguments (files, buffers, options, themes, help topics), extending to what the candidates share; `define-ex-completion!` adds more.

## Keys and options

`:set` takes `no`, `?`, `!` and `=`. Options: `tabstop shiftwidth expandtab autoindent smartindent wrapscan hlsearch incsearch clipboard number relativenumber cursorline wrap linebreak signcolumn splitbelow splitright`. `cmdline-completion #f` gives back Vim's wildmenu.

## Out of scope

- Vimscript. Configuration is Scheme ([[0010-config-in-init-scm]]).

## Known gaps

- No `:map` or `:noremap`; bind keys with `define-key!` in Scheme.
- Which-key shows for the leader and Emacs prefixes, not for Vim's `g` and `z`.
- Block visual mode counts char columns (a tab is one), unlike the renderer, which measures display width.
- Undo is whole-text snapshots with no undo tree, and undo doesn't restore marks.
- Search copies the rope to a string per search (about 3 ms on 100k lines).
