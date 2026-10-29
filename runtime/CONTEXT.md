# runtime

The editor, in Steel Scheme: every command, keymap and mode, the Vim engine included ([[0005-rust-owns-data-and-speed-scheme-owns-behavior]]). Steel's quirks are in [[steel]].

## Load order

The files load in the order of `RUNTIME` in `crates/imp-server/src/lib.rs`: `core.scm` (evaluation, keymaps, commands, hooks, advice, options, faces) first, then `fold`, `vim`, `help`, `completion`, `leader`, `modes`, `map`, `special`, `emacs`, `packages`, `files`, `repl`, `syntax`, `grammars`, `foldmethod`, `complete`, `snippet`, `lsp`, `dap`, `mouse`, `mcp`, `git`, `calendar`, `org`, `org-agenda`, `dired`, `project`, `term`, `claude`, `start`, `wasm`, `collab`, `theme`, `config`. Then the user's `init.scm`, then `(imp-init)`. An error in `init.scm` goes to the status line and the editor still starts; runtime errors are caught and shown as `error: ...`.

## Rules

- Every function and command has an Emacs-style docstring: a string first in its body (or in the command's lambda), its first line a sentence of its own. Help and M-x show it. Variables and options get a comment above. `tools/docstrings.py missing` lists gaps.
- A file can't call a function first defined in a later file, and a `define` there won't replace an earlier file's function for its callers. To extend across files, use hooks, tables (`*extra-states*`) or variables set with `set!` (`*key-interceptor*`, `*local-keymaps*`, `*cmdline-key-handler*`, `*typed-char-handler*`, which `syntax.scm` sets to close end tags).
- Show a package's buffers with `display-buffer!`, not `go-to-buffer!`, so popup rules apply.
- A buffer's mode keys come before Vim's operators, motions, prefixes and the `/` and `?` search prompts, so special buffers can bind `c`, `d`, `q`, `g`, `?`. A mode's key sequences may start with a letter too (the agenda's `ct`, `dd`): in normal and visual state, while a mode binds longer keys starting with it, that letter waits for the rest instead of being Vim's, unless it is a Vim prefix (`g`, `z`, `Z`), whose sequences go through Vim.

## Extension points

- Keys and commands: `define-command!`, `define-key!` (takes a command name, looked up when pressed, and an optional which-key label, as `define-motion!`, `define-operator!` and `define-mode-key!` do), `run-command`, `define-leader!`, `define-leader-group!`, `define-mode-leader!` (under `SPC m`), `define-mode-leader-group!`, `document-command!`. A feature someone runs is a command, named in kebab-case so M-x finds it, and `:NAME` runs it too; `define-ex!` is only for Vim's own ex commands ([[0019-interactive-features-are-m-x-commands-ex-commands-are-vim-s]]). A command that needs an answer asks for it with `completing-read` or `open-cmdline!`: `:NAME text` answers that prompt. One whose question isn't a prompt (a menu of keys) reads the text with `(command-argument)`.
- Vim (`vim.scm`): `define-motion!` (type `'exclusive`, `'inclusive` or `'linewise`), `define-char-motion!`, `define-text-object!`, `define-operator!`, `define-char-command!`, `define-prefix!`, `define-ex!`, the `:map` family (`map.scm`, its keymaps `map:normal`, `map:visual`, `map:insert`), `define-ex-completion!`, `define-state!`. Call `(begin-change!)` before a change; `with-undo-group` makes several changes one undo step. Motions work with every operator, visual mode, counts and `.`.
- Modes: `define-major-mode!`, `define-minor-mode!`, `define-mode-key!`, `define-file-name-mode!`, `set-local-option!`, `buffer-local`. A mode's setup sets its bracket and quote pairs with `set-mode-pairs!`, which gives way to a global `auto-pairs-chars`.
- Changes: `(buffer-changes-since version)` lists a buffer's edits since a version (keep your own version; nothing is used up), and `(after-change-range)` is what the key changed, inside `after-change`.
- Hooks: `startup after-change before-save after-save post-command insert-enter insert-leave mode-change major-mode buffer-enter buffer-open buffer-kill buffer-renamed option-change`; advice with `advice-add!` (`'before`, `'after`, `'around`).
- Options: `define-option!`, `define-computed-option!`, `option`, `set-option!`, `watch-option!`, `option-set?` (whether it was set globally, so a per-buffer default can give way to the user's choice).
- Background: `run-after!`, `run-every!`, `start-job!`.
- Completion: `completing-read`, `define-completion-source!`, `set-completion-sources!`, `define-snippet!`.
- Languages: `define-mode-language!`, `define-syntax-objects!`, `syntax-ancestors` (the buffer's own tree) and `syntax-at` (the innermost language at an offset, a fence's or a `<script>`'s, and its nodes) with `syntax-children-at` for that tree's children, `define-syntax-folds!` (node kinds for foldmethod syntax), `define-language-server!`, `define-debug-adapter!`.
- Special buffers (`special.scm`): `special-mode`, `menu!` (entries may be short key sequences, `gr`), `confirm!`, `draw-line!`, `define-popup-rule!`, `set-footer!` for lines pinned at the bottom of a buffer's windows, and `set-line-end-text!` for text after a line's end.
- Themes: `define-theme!`, `load-theme!`; MCP: `define-mcp-tool!`; sockets: `listen-socket!`.

## Notes

- Dot-repeat of an insert replays the typed keys, as Vim does. A paste is recorded between `<paste-start>` and `<paste-end>`, so replaying it doesn't auto-pair.
