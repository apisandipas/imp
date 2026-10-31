---
type: Effort
status: active
specs: ["[[spec/leader-and-modes]]", "[[spec/live-scheme-and-help]]", "[[spec/vim]]"]
issue: https://github.com/apisandipas/imp/issues/122
frozen:
  docs/specs/leader-and-modes.md: 31edc02513df
  docs/specs/live-scheme-and-help.md: ccb5a072e58a
  docs/specs/vim.md: 51ce58e56b12
---
# Key resolver

One rule for which binding a key runs in normal and visual state, used by dispatch, which-key, describe-key and `:map`.

## Approach

`resolve-key` goes in `vim.scm` just before `normal-key!`. It takes the state, a complete key and the pending operator, and returns a binding record: kind, procedure, which-key label and command name. Its order is the one `normal-key!` checks today. It comes first, with its own tests, while nothing calls it yet. Then `normal-key!` is changed to run the record. It keeps counts, prefixes, registers and the search prompt, and asks `resolve-key` for a mode key wherever it calls `local-key-proc` now. The Vim tests don't change, so they show no key runs anything new. `bench.rs` runs before that change and after it. If keys are more than about 5% slower, `resolve-key` is made cheaper; the order is never split in two again. Then the three describers read the record, one per task, each with its own reference page. Lookups in insert and Emacs state, `foldmethod.scm` and the ex-command fallback at `vim.scm:4723` are left alone.

## Tasks

- [x] Baseline: run `cargo run --release -p imp-server --example bench` on `develop`'s code and keep the numbers in this effort's notes below, to compare against later.
- [x] Resolver: `(resolve-key state key [operator])` in `vim.scm` returns a binding record, or `#f` for a key that does nothing. Record kinds: `mode-key`, `visual-key`, `operator`, `text-object`, `motion`, `normal-key`, `char-command`, `operator-again` or `prefix`. Order: normal state, visual state, operator pending, a prefix alone. Nothing calls it yet. Each precedence case is tested in a new `tests/resolve_key.rs`: a git status mode key over operator `d`, a visual key over an operator, `dd` and `gUU` as `operator-again`, `g` as `prefix`, an unbound key as `#f`. "Binding record" and "key resolution" are added to `runtime/CONTEXT.md`. The anchors `symbol:resolve-key` and the test file go on `leader-and-modes.md`.
- [x] Dispatch: `normal-key!` runs the record from `resolve-key`, and the checks for a digit, `/`, `?` and a prefix ask `resolve-key` whether a mode key takes the key. Every existing test passes unchanged: vim, leader, modes, map, help, git and start screen. `bench.rs` runs again. If keys are more than about 5% slower, `resolve-key` is made cheaper before this task is done, and both sets of numbers go in the notes.
- [x] Which-key: `binding-label` and `prefix-continuations` read the record, so visual which-key also lists text objects and char commands after a prefix. Tested in `leader.rs`. `ref-leader-and-modes.md` is rewritten for the revised spec, documenting `resolve-key`, and frozen.
- [x] describe-key: `key-description` reads the record for normal state in the current buffer. It still finds the site where a key was bound itself. Tested in `help.rs`: `d` in git status is the mode's command, and `w`, `x`, `fx` and `d` in a plain buffer are described as before. `ref-live-scheme-and-help.md` is updated and frozen.
- [x] `:map`: `key-does-something?` asks `resolve-key`. The existing map tests pass unchanged, with a test of a key that only a mode binds. `ref-vim.md` is updated and frozen.

## Notes

Baseline on `develop` (87017b3), `bench.rs` in release, 20 runs each, ms per command including a frame. The sub-millisecond ones vary by run, so compare several runs, not one.

| Keys | ms | Keys | ms |
|---|---|---|---|
| `j` | 0.18 | `/words<ret>` | 4.22 |
| `w` | 0.19 | `n` | 0.43 |
| `x` | 0.23 | `50%` | 0.35 |
| `dd` | 0.27 | `ci(` | 6.41 |
| `ihello<esc>` | 0.92 | `dit` (no tags) | 0.73 |
| `G` | 0.23 | `}` | 2.03 |
| `gg` | 0.69 | `vjjd` | 0.48 |
| `u` | 0.22 | | |

After dispatch moved to `resolve-key`, three runs each of the old and new dispatch (ms, before → after, mean change):

| Keys | Before | After | Change |
|---|---|---|---|
| `j` | 0.18 0.19 0.18 | 0.19 0.19 0.19 | +3.6% |
| `dd` | 0.26 0.27 0.27 | 0.27 0.28 0.28 | +3.8% |
| `G` | 0.23 0.24 0.24 | 0.24 0.28 0.23 | +5.6% (one outlier; medians equal) |
| `50%` | 0.35 0.36 0.36 | 0.38 0.37 0.37 | +4.7% |
| `vjjd` | 0.49 0.50 0.48 | 0.47 0.47 0.47 | −4.1% |

The rest are within ±3%: `w`, `x`, `ihello<esc>`, `gg`, `u`, `/words<ret>`, `n`, `ci(`, `dit`, `}`. About 0.01 ms a key at most, under the 5% bound, so `resolve-key` was left as it is.
