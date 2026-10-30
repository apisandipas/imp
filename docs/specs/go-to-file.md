---
type: Spec
status: accepted
issue: https://github.com/apisandipas/imp/issues/115
summary: "gf, gF and C-w f open the file named under the cursor: found from the buffer's directory, the project or the working directory, with the mode's endings and, in TypeScript and JavaScript, tsconfig's path aliases."
---
# Go to file

`gf` opens the file whose name is under the cursor, as Vim's does: an import, an include, a path in a log or a comment. `gF` also goes to the line number after it, and `C-w f` opens the file in a split.

## Behaviour

### The name

- The name is the run of file-name characters around the cursor: letters, digits and `/ . - _ ~ + @ % $ # =`. Quotes, brackets, commas and spaces end it, so in `import x from "./form-context";` the cursor anywhere on the string gives `./form-context`.
- On a character that can't be in a name, the name is the next one after the cursor on the line, as in Vim.
- In visual mode the selection is the name, on one line, trimmed of white space.
- A leading `~/` is the home directory, and `$NAME` is the environment variable.
- No name under or after the cursor says "No file name under cursor".

### Where it is looked for

- An absolute name, or one starting with `~/`, is used as it is.
- A relative name is looked for in order: the buffer's directory (a terminal's is the shell's), then the project root, then the working directory. This is Vim's default `path` (`.,,`) with the project root added. The first that exists wins.
- A name starting `./` or `../` is only looked for from the buffer's directory, since that is what it means.
- In each place, the name as written comes first, then the name with each of the buffer's `suffixesadd` endings (in TypeScript and JavaScript buffers `.ts`, `.tsx`, `.d.ts`, `.js`, `.jsx`, `.mts`, `.mjs`, `.cts`, `.cjs`), then, if the name is a directory, `index` with each ending inside it.
- A directory with no `index` file opens in the file browser, as `:e` on a directory does.
- Nothing found says `Can't find file "NAME" in path` and opens nothing, unlike `:e`, which makes an empty buffer.

### Path aliases (TypeScript and JavaScript)

- In TypeScript and JavaScript buffers, the name is also tried through `compilerOptions.paths` from the nearest `tsconfig.json`, or failing that `jsconfig.json`, going up from the buffer's directory. With `"@/*": ["./src/*"]`, `@/components/form/fields` is tried as `src/components/form/fields`, relative to `baseUrl` if set, otherwise to the config's directory, with the same endings and `index` as above.
- An exact pattern (no `*`) matches only the whole name. With several patterns matching, the one with the longest prefix before its `*` is used, as TypeScript does. Each of its targets is tried in order.
- The config may have comments and trailing commas, as tsconfig allows. A relative `extends` is followed, its `paths` used where the file itself sets none.
- Aliases are tried after the name as written, from the buffer's directory, and before the project root.
- This is a mode's lookup, through the option `includeexpr`: a procedure taking the name and returning more names to try, or `#f`. TypeScript and JavaScript modes set it; any mode, or init.scm, can set its own.

### Opening it

- `gf` opens the file in the current window, like `:e`, keeping the jump so `C-o` comes back. A buffer already open on the file is switched to.
- `gF` also goes to the line after the name: `file:42`, `file:42:7` (and column 7), `file(42)` or `file line 42`. With a count, `gF` goes to that line instead. With no line, `gF` is `gf`.
- `C-w f` and `C-w C-f` split the window and open the file in the new one; `C-w F` is `gF` in a split. Nothing found leaves the window unsplit.

## Keys and options

| Key | What it does |
|---|---|
| `gf` | Open the file under the cursor (in visual mode, the selected name) |
| `gF` | `gf`, then go to the line after the name, or line count |
| `C-w f`, `C-w C-f` | `gf` in a new split |
| `C-w F` | `gF` in a new split |

| Option | Default | What it does |
|---|---|---|
| `suffixesadd` | `""` | Endings to try after the name, comma-separated (`.ts,.tsx`); modes set it locally |
| `includeexpr` | `#f` | A procedure from the name to more names to try; TypeScript and JavaScript set tsconfig's aliases |

## Out of scope

- URLs: opening them in a browser is Vim's `gx`, not `gf`.
- Searching down the tree (`path` with `**`) and Vim's `path` option itself.
- Packages: a bare import such as `@tanstack/react-form` is resolved in `node_modules` by the language server, so `gd` goes there; `gf` says it can't find it.
- `extends` naming a package (`"extends": "@tsconfig/node20"`), and project `references`.
- `[count]gf` picking the count'th match, and `C-w gf` (imp has no tab pages).

## Known gaps
