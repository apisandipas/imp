---
type: Page
spec: "[[spec/completion-at-point]]"
frozen:
  docs/specs/completion-at-point.md: 7a992144e52e
---
# Completion while typing

In insert mode, a menu at the cursor offers ways to finish the word you're typing: file paths, words from your buffers, names from a language server, and snippets. It works like nvim-cmp. For the menu at the prompt, such as `M-x`, see [Completion at the prompt](ref-completion.md).

## Opening the menu

In code, the menu opens by itself once you've typed three characters of a word. Elsewhere, ask for it:

| Key | What it does |
|---|---|
| `C-n` | Open the menu, the first choice selected |
| `C-p` | Open the menu, the last choice selected |
| `C-x C-o` | Open the menu |

Where a language server is running, it also offers its names as you type. See [Language servers](ref-lsp.md).

## Choosing

Keep typing to narrow the menu. Which keys move and accept depends on `completion-keys`:

| `completion-keys` | Move | Accept | `<ret>` |
|---|---|---|---|
| `vim` (the default) | `C-n` `C-p` `<tab>` `<s-tab>` | `C-y` | Accepts once you've selected a choice |
| `tab` | `C-n` `C-p` `<s-tab>` | `<tab>` | A new line |
| `enter` | `C-n` `C-p` `<tab>` `<s-tab>` | `<ret>` | Accepts |

With `tab` or `enter`, accepting with nothing selected takes the first choice. `C-e` closes the menu.

```scheme
(set-option! 'completion-keys 'tab)
```

## Where the choices come from

The choices come from sources:

- **file**: the entries of a directory, when what you type looks like a path
- **lsp**: the language server, when the buffer has one
- **scheme**: in Scheme buffers, the names imp defines
- **words**: words from this buffer, nearest the cursor first, then from your other buffers

Sources come in groups. imp tries each group in turn, and the first that has anything fills the menu. The default groups are `(file (lsp scheme words))`: a path completes on its own, and anything else from the other three together.

To change them for a major mode, use `set-completion-sources!`. Each item is a group, or a source alone:

```scheme
(set-completion-sources! 'markdown-mode '(file words))   ; file, else words
(set-completion-sources! 'org-mode '((file words)))      ; both together
```

## Snippets

A snippet is text with stops to fill in. Its prefix shows in the menu like a word, and accepting it puts in the snippet. Snippets from a language server work the same way.

| Key | What it does |
|---|---|
| `<tab>` | Go to the next stop |
| `<s-tab>` | Go to the previous stop |

A stop that holds a placeholder starts selected, so typing replaces it. A stop with choices offers them in the menu.

Snippets use the syntax of VS Code and LSP:

| You write | You get |
|---|---|
| `$1`, `$2` | Stops, in order |
| `${1:name}` | A stop with a placeholder |
| `${1\|one,two\|}` | A stop with choices |
| `$0` | Where the cursor ends up |

Define your own in `init.scm`, for a major mode or for `'all`. `load-snippets!` reads a VS Code snippet file:

```scheme
(define-snippet! 'rust-mode "fn" "fn ${1:name}(${2}) {\n\t$0\n}" "function")
(load-snippets! 'rust-mode "~/snippets/rust.json")
```

## On the command line

The command line has its own menu. After `:` it completes command names and their arguments. After `/` or `?` it completes words from the buffer.

## A source of your own

`define-completion-source!` adds a source. Its procedure gets `manual?`, true when you asked with a key, and `done`. It returns `#f` when it has nothing here. Otherwise it calls `done` with where the text it completes starts and the choices, and returns `#t`:

```scheme
(define-completion-source! 'greetings
  (lambda (manual? done)
    (done (word-start-before (cursor))
          (list (completion-candidate "hello") (completion-candidate "goodbye")))
    #t)
  'priority 10)
```

After the procedure come settings: `'priority N` ranks it among equally good matches, `'min-length N` is how many characters to type before it's asked, and `'exclusive #t` puts it in a group of its own. `'auto` takes a procedure, called with each character you type, that says whether to ask the source now.

## Options

| Option | Default | What it does |
|---|---|---|
| `completion-keys` | `'vim` | Which keys move and accept: `'vim`, `'tab` or `'enter` |
| `completion-auto-modes` | `'(prog-mode)` | Major modes where the menu opens by itself, and their children |
| `completion-auto-min` | `3` | Characters of a word to type before the menu opens by itself |
| `completion-menu-columns` | `'(icon label detail)` | What each row shows, from `icon`, `label`, `detail` and `source` |
| `completion-words-scope` | `'all` | Where words come from: `'all` your file buffers, or `'current` |
| `cmdline-completion` | `#t` | The menu on the command line |
