---
type: Effort
status: done
specs: ["[[spec/tree-sitter]]"]
issue: https://github.com/apisandipas/imp/issues/81
frozen:
  docs/specs/tree-sitter.md: 0f8ff7a1b057
---
# Runtime grammars

## Approach

Scheme declares, installs and tracks grammars; Rust loads and compiles them, lazily. The split follows the rest of imp: what can be Scheme is.

**Installing** is a new `runtime/grammars.scm`, which runs `git` and the C compiler with `start-job!`, the way `packages.scm` clones packages. Each grammar's declared revision is fetched, shallow, into `grammars/NAME/` under `$XDG_DATA_HOME/imp` (`(grammars-dir)`, a function tests redefine). Its build goes to `grammars/NAME@REV.so` (an `@`, not a dash, so removing grammar `c`'s old builds can't catch `c-sharp`'s). The revision in the file name is what "built at its declared revision" means, and it gives every revision its own path. That matters because `dlopen` hands back the library it already has for a path it has seen, and overwriting a loaded library in place can crash the process. The build writes to a temporary file and renames it, then removes the other revisions' libraries; unlinking a loaded one is safe.

**Loading** is Rust, with `libloading` (already in `Cargo.lock` through the window client, so nothing new is downloaded). `(register-grammar! name library queries-dir)` records a built grammar without loading it. `define-grammar!` calls it when the build for the declared revision exists, and an install calls it when it finishes. The library is opened and `tree_sitter_NAME` called (dashes as underscores) the first time anything looks the language up, whether a buffer or an injection. The language registry becomes a lookup that checks registered grammars before bundled ones and compiles each language's queries on first use, caching the result. Registering again replaces a cached entry, so buffers opened afterwards use the new build. A failed load (no such symbol, an incompatible ABI) is reported to `set-buffer-language!`, which returns the reason for Scheme to show. An injection that fails stays plain.

**Queries** are resolved in Rust, in the same lookup. For each of `highlights` and `injections`, the order is:
1. `NAME/KIND.scm` under the query directory: `queries/` beside the config file, set by the server when it starts (none without a config file, as in tests), and changed with `(set-query-dir! dir)`;
2. else the grammar repository's `queries/KIND.scm`;
3. else the bundled crate's query.

A file whose first lines include `; inherits: a,b` gets those languages' queries, resolved the same way, put before it. Each language is included once, which also stops cycles.

The tests use a tiny grammar, generated once with the tree-sitter CLI and committed with its `src/parser.c` under `crates/imp-server/tests/fixtures/`. A test makes a local git repository of it, so installing runs the real `git` and `cc`. Each task updates `docs/reference/ref-tree-sitter.md` in the same commit.

## Tasks

- [x] Loading: the test grammar fixture, `register-grammar!` and the lazy lookup with `libloading`. A registered grammar works like a bundled one: `set-buffer-language!` and `define-mode-language!` use it, it highlights, it has text objects through `define-syntax-objects!`, and a Markdown fence names it by name or alias. A grammar registered with a bundled one's name takes its place. A library without the `tree_sitter_NAME` symbol, or one built for an incompatible tree-sitter, gives a message naming the problem, and the buffer is plain. Tests compile the fixture with `cc`.
- [x] Queries: highlights and injections come from the grammar repository's `queries/`. `queries/NAME/highlights.scm` and `queries/NAME/injections.scm` in the config directory replace them for any language, bundled or not. `; inherits: a,b` puts those languages' queries first, each once, and a cycle stops. With tests, including an override of a bundled language's highlights.
- [x] Installing: `(define-grammar! "name" "git-url" "rev" [subdir])` and the commands `install-grammars` and `install-grammar` (renamed from `:TSInstallGrammar`, [[0019-interactive-features-are-m-x-commands-ex-commands-are-vim-s]]):
  - `install-grammars` installs every declared grammar not built at its declared revision. `install-grammar` asks for one, saying which are built, and installs or rebuilds it.
  - Installing clones (or fetches) into `grammars/NAME/`, checks out the revision, and compiles `src/parser.c`, plus `src/scanner.c` or `src/scanner.cc` if present, with `$CC`, else `cc`, or `c++` for a C++ scanner. The build goes to `NAME@REV.so` through a temporary file, and the old revisions' libraries are removed.
  - It runs in the background, saying in the message line what it's doing and when each grammar is done or failed. Without `git` or a C compiler it fails with a message naming what's missing.
  - With tests against a local repository of the fixture, including a subdirectory grammar and a rebuild.
- [x] On use: a buffer whose language is declared but not built shows a message saying to run M-x `install-grammars`, and nothing is cloned or built. When an install finishes, buffers already open in that language are highlighted without reopening them. `define-grammar!` of an already built grammar makes it available at startup without loading it. With tests, and a manual check, with a screenshot, that `ruby-mode` lights up with the real Ruby grammar installed from GitHub.
