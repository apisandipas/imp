# Coming from Emacs or Vim

imp takes its editing from Vim and its idea from Emacs: the editor is written in its own language, and you can change any of it while it runs. Here's what carries over, and what doesn't.

## From Vim

Your hands already know imp. Motions, operators, text objects, counts, `.`, registers, macros, marks, visual mode, `/` search, `:s`, `:g`, folds, splits and buffers all work as in Vim. See [Vim](ref-vim.md).

What's different:

- **Configuration is Scheme, not Vimscript.** `init.scm` takes the place of `.vimrc`. The `:map` family still works, from the command line or with `(run-ex! "nnoremap ...")`. See [Configuring init.scm](configuring.md).
- **Space is the leader.** `SPC` opens a menu of everything you can do next, and `M-x` runs any command by name. See [Leader and modes](ref-leader-and-modes.md).
- **Plugins are packages.** Git, Org, a file browser, language servers, completion and terminals come built in. Extras are packages; see [Packages](packages.md).
- **Some mappings aren't supported:** `:omap`, `:xmap`, `:smap`, `:cmap` and `:tmap`, and the `<buffer>` and `<expr>` arguments.
- **No undo by time.** `:earlier 10m` and `:later` don't exist, and undo history isn't kept after you close a file.

## From Emacs

What feels familiar:

- **The editor is its own language.** Most of imp is Scheme. `SPC h f` shows any function's docs and where it's defined, and you can redefine it on the spot. See [Live Scheme and help](ref-live-scheme-and-help.md).
- **Evaluate as you go.** In a Scheme buffer, `SPC e e` runs the form at the cursor, `SPC e b` the buffer, and `SPC e i` opens a REPL.
- **Hooks and advice.** `add-hook!` and `advice-add!` work much like Emacs's.
- **The packages you'd miss.** A Magit-style git interface (`SPC g g`), Org mode with an agenda and capture, and an editable file browser like dired. See [Git](ref-git.md), [Org](ref-org.md) and [File browser](ref-dired.md).
- **`M-x`.** It lists every command, with its key and what it does.

What's different:

- **Scheme, not Elisp.** imp can't run Emacs's packages or your Emacs config.
- **Vim keys by default.** Press `C-z` to switch to Emacs state, where keys insert text and Emacs keys edit: `C-x C-f`, `C-x C-s`, `C-k`, `C-y`, `C-s` and the rest. `C-z` switches back.

To start in Emacs state every time, add this to `init.scm`:

```scheme
(set-option! 'editing-style "emacs")
```

See [Emacs state](ref-emacs-state.md) for the keys it has.
