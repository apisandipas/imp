---
type: Page
spec: "[[spec/go-to-file]]"
frozen:
  docs/specs/go-to-file.md: a8aeb43841a1
---
# Go to file

Put the cursor on a file name and press `gf` to open that file: an import, an include, a path in a log or a comment. `C-o` takes you back.

## The name

The name is the run of characters around the cursor that can be in a file name. Quotes, brackets, commas and spaces end it, so anywhere on the string in

```ts
import { fieldContext } from "./form-context";
```

`gf` reads `./form-context`. With the cursor on something that can't be in a name, such as a space or a quote, `gf` takes the next name on the line.

To give the name yourself, select it in visual mode and press `gf`. This is how to open a name with spaces in it.

`~/` is your home directory, and `$NAME` or `${NAME}` is an environment variable.

## Where it looks

A relative name is looked for in the buffer's directory first, then the project's root, then imp's working directory, and the first that exists opens. In a terminal, the buffer's directory is the shell's. A name that starts with `./` or `../` is only looked for from the buffer's directory, since that's what it means.

When the name has no ending, as imports often don't, `gf` also tries the endings in `suffixesadd`. TypeScript and JavaScript buffers try `.ts`, `.tsx`, `.d.ts`, `.js`, `.jsx`, `.mts`, `.mjs`, `.cts` and `.cjs`, so `./form-context` opens `form-context.ts`. If the name is a directory, `gf` opens the `index` file in it with one of those endings. A directory with no `index` file opens in the file browser.

If nothing is found, `gf` says `Can't find file "NAME" in path` and opens nothing. It never makes an empty buffer the way `:e` does.

For another language, set the endings in its mode's setup:

```scheme
(define-major-mode! 'lua-mode 'prog-mode '("lua")
  (lambda () (set-local-option! 'suffixesadd ".lua")))
```

## Lines and splits

`gF` also goes to the line written after the name, as compilers, test runners and stack traces write it: `src/main.rs:42`, `src/main.rs:42:7` (line 42, column 7), `main.c(42)` or `main.c line 42`. With a count, `12gF` goes to line 12 instead. With no line after the name, `gF` does what `gf` does.

`C-w f` opens the file in a new split, and `C-w F` does the same as `gF`. If the file can't be found, the window isn't split.

## Keys

| Key | What it does |
|---|---|
| `gf` | Open the file under the cursor (in visual mode, the selected name) |
| `gF` | Open it and go to the line after the name, or to the count's line |
| `C-w f`, `C-w C-f` | Open it in a new split |
| `C-w F` | `gF` in a new split |

## Options

| Option | Default | What it does |
|---|---|---|
| `suffixesadd` (`sua`) | `""` | Endings to try after a name, comma-separated (`.ts,.tsx`); TypeScript and JavaScript set their own |
