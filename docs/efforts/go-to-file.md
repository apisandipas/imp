---
type: Effort
status: done
specs: ["[[spec/go-to-file]]"]
issue: https://github.com/apisandipas/imp/issues/115
frozen:
  docs/specs/go-to-file.md: a8aeb43841a1
---
# Go to file

## Approach

A new `runtime/gofile.scm`, loaded after `project.scm` and `term.scm`, as it needs `project-root` and `buffer-directory`, and opens through `open-file!` (directories go to the file browser). Finding the file is a list of candidate paths tried in order, so each rule (the places, `suffixesadd`, `index`, `includeexpr`) only adds candidates and the order in the spec is the order of the list. The tsconfig aliases are Scheme too: the config is small, read once per lookup, with its comments and trailing commas stripped before `json-decode`. Three slices, each its own commit with its tests in `tests/go_to_file.rs`, the reference page growing with them.

## Tasks

- [x] `gf` in normal and visual mode: the name under or after the cursor, looked for from the buffer's directory, the project root and the working directory (`./` and `../` only from the first), with `suffixesadd` and `index`, `~/` and `$NAME`, directories to the file browser, and "Can't find file" when nothing is there; `suffixesadd` set by TypeScript and JavaScript modes; with tests and the reference page.
- [x] `gF` (`file:42`, `file:42:7`, `file(42)`, `file line 42`, a count) and `C-w f`, `C-w C-f`, `C-w F` in a split that isn't made when nothing is found, with tests.
- [x] `includeexpr`, and TypeScript and JavaScript's tsconfig and jsconfig `paths` through it: nearest config, `baseUrl`, exact and `*` patterns with the longest prefix winning, comments and trailing commas, a relative `extends`, tried between the buffer's directory and the project root; with tests.
