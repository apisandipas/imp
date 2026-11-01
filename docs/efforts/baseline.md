---
type: Effort
status: done
specs: ["[[spec/buffers-and-windows]]", "[[spec/claude]]", "[[spec/command-line]]", "[[spec/completion-at-point]]", "[[spec/completion]]", "[[spec/daemon]]", "[[spec/dap]]", "[[spec/dired]]", "[[spec/emacs-state]]", "[[spec/files]]", "[[spec/folding]]", "[[spec/git]]", "[[spec/kdl-config]]", "[[spec/live-scheme-and-help]]", "[[spec/look]]", "[[spec/lsp]]", "[[spec/mcp]]", "[[spec/mouse]]", "[[spec/move-lines]]", "[[spec/olivetti]]", "[[spec/org]]", "[[spec/packages]]", "[[spec/posframe]]", "[[spec/projects]]", "[[spec/shared-buffers]]", "[[spec/start-screen]]", "[[spec/terminals]]", "[[spec/tree-sitter]]", "[[spec/vim]]", "[[spec/wasm-plugins]]"]
frozen:
  docs/specs/buffers-and-windows.md: bc8c82b25ab1
  docs/specs/claude.md: ea885bd760a5
  docs/specs/command-line.md: 552dffb88851
  docs/specs/completion-at-point.md: 7a992144e52e
  docs/specs/completion.md: ca9eec425099
  docs/specs/daemon.md: 1ae89cf0fc57
  docs/specs/dap.md: b1a36380474b
  docs/specs/dired.md: a02aeaac49d8
  docs/specs/emacs-state.md: b74c1fe8672a
  docs/specs/files.md: b452a5d99077
  docs/specs/folding.md: 2596f3a5ab7f
  docs/specs/git.md: 784db8c1c823
  docs/specs/kdl-config.md: ed960468150c
  docs/specs/live-scheme-and-help.md: ccb5a072e58a
  docs/specs/look.md: 966eea438d82
  docs/specs/lsp.md: 521f968e45ec
  docs/specs/mcp.md: eb9a936be6e7
  docs/specs/mouse.md: 9ddcdd15e5ad
  docs/specs/move-lines.md: d4c34470f45d
  docs/specs/olivetti.md: 5b1ed15a4236
  docs/specs/org.md: eacefd3dbd04
  docs/specs/packages.md: e9a16175b04a
  docs/specs/posframe.md: 9dd5f8aa7b18
  docs/specs/projects.md: fac9a61f6afa
  docs/specs/shared-buffers.md: 42534f57ec33
  docs/specs/start-screen.md: 3a63b6f3dc40
  docs/specs/terminals.md: 127f6a0b5b15
  docs/specs/tree-sitter.md: 4a87962c1110
  docs/specs/vim.md: 51ce58e56b12
  docs/specs/wasm-plugins.md: b62f9140ac75
---
# Baseline

The specs that describe what imp already did when efforts started being tracked, so `lore next` does not offer to plan them.

## Approach

Nothing to build: each linked spec was written to describe existing code. Freezing this effort records their versions; when one changes, `lore next` says so. A feature that changes one gets its own effort. A small fix that only edits one (a known gap removed) runs `lore freeze docs/efforts/baseline.md` in the same commit.

## Tasks

- [x] Built before efforts were tracked.
