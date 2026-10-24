---
status: accepted
issue: https://github.com/apisandipas/imp/issues/8
summary: "Vim's normal, insert, visual and command-line behavior, matched against real Vim."
anchors: [runtime/vim.scm, runtime/map.scm, crates/imp-server/tests/map.rs, crates/imp-server/src/search.rs, crates/imp-server/src/scan.rs, crates/imp-server/tests/vim.rs]
---
# Vim

imp is Vim-first ([[0006-vim-by-default-in-the-core]]). Everything here behaves as Vim does; where it doesn't, that's a bug.

## Behaviour

- **Motions**: `h j k l w b e ge W B E gE 0 ^ $ | + - _ <ret> gg G N% { } % H M L f F t T ; , n N * # g* g#`, arrows, `<home> <end>`, marks `'x` and `` `x``, `gj gk` by screen rows. Vim's rules for exclusive motions and the `dw`/`cw` special cases. A motion can fail: that cancels an operator, stops a macro, and lets `h j k l` fail at edges.
- **Text objects**: `iw aw iW aW`, quotes (on the cursor's line only), every bracket kind, `it at`, `ip ap`; tree-sitter adds `af if ac ic aa ia` ([[tree-sitter]]). `aw` takes trailing white space, else leading; `i{` on braces on their own lines is linewise over the inner lines.
- **Operators**: `d c y > < gu gU g~ g? gc`, doubled forms, counts that multiply. A linewise range is always whole lines; only `d` knows the final-newline case.
- **Commands**: `x X D C s S Y p P gp gP r R J gJ ~ C-a C-x u C-r U . & ZZ ZQ C-g i a I A o O gi gI`, counts on inserts and pastes.
- **Visual**: `v V C-v`, `o O gv`, operators and text objects, `I A c r J p u U ~ > <`, block `$`, and `.` over the same size of region. `:` from visual uses the `<` and `>` marks. Blocks are display columns: a tab or wide char at a corner widens the block to all of it, and one the block's edge cuts becomes spaces where text is taken out or put in.
- **Insert**: autoindent and smartindent, expandtab-aware `<tab>`, `C-w C-u C-h C-t C-d C-r C-o`, `<del> <home> <end> <up> <down>`; Replace mode restores on `<bs>`.
- **Search**: `/ ? n N * #`, incremental and highlighted (`:noh`), as a motion (`d/foo`), smartcase, Vim regex syntax translated to the `regex` crate.
- **Registers**: `"a-z "A-Z "0-9 "- "_ ". ": "/ "% "+ "*`, `clipboard=unnamedplus`, `"1p..`. The system clipboard goes through `wl-copy`, `xclip`, `xsel` or `pbcopy`.
- **Macros**: `q @ @@ @:`; a failing key stops a macro. Keys are stored as text in Vim notation.
- **Marks and jumps**: `a-zA-Z ' . ^ [ ] < >` (marks live in the buffer and move with edits), the jump list `C-o C-i` across buffers.
- **Scrolling**: `C-d C-u C-f C-b C-e C-y zt zz zb z<ret> z. z-`.
- **Ex**: ranges (`. $ N 'x /pat/ ?pat? %` and offsets); `:w [file] :w! :sav :q :wq :x :qa :e`; `:s` with `g i I`, groups, `&`, `\r`; `:d :y :m :t :> :< :j :pu :k :p :nu :sort :normal :g :v :! :r :u :red :noh :set :setlocal :marks :reg :jumps :delm`; command-line history and editing keys, `C-r`. `<tab>` completes command names and their arguments (files, buffers, options, themes, help topics), extending to what the candidates share; `define-ex-completion!` adds more.
- **Mappings**: `:map`, `:nmap`, `:vmap` and `:imap` bind `{lhs}` to typing `{rhs}`; `:noremap`, `:nnoremap`, `:vnoremap` and `:inoremap` do the same, but their `{rhs}` runs imp's own keys, not other mappings. `:map` and `:noremap` cover normal and visual state. Both sides take Vim's key notation, case-insensitive: `<CR>`, `<Esc>`, `<Tab>`, `<BS>`, `<Space>`, `<lt>`, `<Bar>`, `<C-x>`, `<M-x>`, arrows, `<F1>`, and `<Leader>` (space). A recursive `{rhs}` stops after 100 levels with an error.
  - A mapping comes after the buffer's mode keys and before Vim's own keys, motions, operators and prefixes, so `:nnoremap j gj` works. A count typed before it applies to its `{rhs}`, as in Vim.
  - In normal and visual state, an `{lhs}` of two keys must start with a prefix (`g`, `z`, `Z`, `[`, `]`, `C-w`) or a key nothing is bound to, which becomes a prefix; a longer one must start with `<Leader>`, and adds to the leader tree in both states. Otherwise `:map` says why it can't.
  - In insert state an `{lhs}` can be any keys: `:inoremap jk <Esc>` inserts `j`, and if `k` follows within `timeoutlen` (1000 ms) the `j` is removed and `<Esc>` runs, as in Vim.
  - Which-key shows a mapping's `{rhs}` as its label.
  - `:unmap`, `:nunmap`, `:vunmap` and `:iunmap` remove a mapping. With no arguments the map commands list the mappings made with them; with only an `{lhs}`, that mapping.

## Keys and options

`:set` takes `no`, `?`, `!` and `=`. Options: `tabstop shiftwidth expandtab autoindent smartindent wrapscan hlsearch incsearch clipboard number relativenumber cursorline wrap linebreak signcolumn splitbelow splitright timeoutlen`. `cmdline-completion #f` gives back Vim's wildmenu.

## Out of scope

- Mappings in operator-pending, select, command-line and terminal state (`:omap`, `:xmap`, `:smap`, `:cmap`, `:tmap`), and the `<buffer>`, `<expr>`, `<script>` and `<unique>` arguments; `<silent>` is accepted and changes nothing.
- A normal-state `{lhs}` of several keys starting with a key that already does something (`,w`), which Vim resolves with a timeout.
- Vimscript. Configuration is Scheme ([[0010-config-in-init-scm]]).

## Known gaps

- Undo is whole-text snapshots with no undo tree, and undo doesn't restore marks. [#5](https://github.com/apisandipas/imp/issues/5)
