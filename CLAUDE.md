imp is an Emacs-flexible, Vim-first editor: a small Rust core with the
editor itself written in Steel Scheme (`runtime/*.scm`). Read
`docs/HANDOFF.md` before starting work: it has the decisions already made,
the architecture, known limitations and the roadmap.

`nix develop` sets `IMP_RUNTIME=$PWD/runtime` so Scheme edits need only a
restart. Before committing, run `cargo test`, `cargo clippy --all-targets` and
`cargo fmt --check`.

New editing behavior goes in Scheme, not Rust. Add a primitive to
`crates/imp-server/src/api.rs` only when Scheme can't do it or is measurably
too slow. Test Vim behavior by feeding keys (see `crates/imp-server/tests/vim.rs`)
and match what real Vim does.
