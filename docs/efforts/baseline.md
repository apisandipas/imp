---
type: Effort
status: done
specs: ["[[spec/buffers-and-windows]]", "[[spec/claude]]", "[[spec/completion-at-point]]", "[[spec/completion]]", "[[spec/daemon]]", "[[spec/dap]]", "[[spec/dired]]", "[[spec/emacs-state]]", "[[spec/files]]", "[[spec/folding]]", "[[spec/git]]", "[[spec/kdl-config]]", "[[spec/live-scheme-and-help]]", "[[spec/look]]", "[[spec/lsp]]", "[[spec/mcp]]", "[[spec/mouse]]", "[[spec/org]]", "[[spec/packages]]", "[[spec/projects]]", "[[spec/shared-buffers]]", "[[spec/start-screen]]", "[[spec/terminals]]", "[[spec/tree-sitter]]", "[[spec/vim]]", "[[spec/wasm-plugins]]"]
frozen:
  docs/specs/buffers-and-windows.md: b71f00fec527
  docs/specs/claude.md: 580fb164d4a1
  docs/specs/completion-at-point.md: 7a992144e52e
  docs/specs/completion.md: c12abe1827ac
  docs/specs/daemon.md: 52dfa8b283fe
  docs/specs/dap.md: b1a36380474b
  docs/specs/dired.md: a02aeaac49d8
  docs/specs/emacs-state.md: b74c1fe8672a
  docs/specs/files.md: b08542837535
  docs/specs/folding.md: 2596f3a5ab7f
  docs/specs/git.md: 784db8c1c823
  docs/specs/kdl-config.md: ed960468150c
  docs/specs/live-scheme-and-help.md: 1857073a1b00
  docs/specs/look.md: 79bbab33f2c1
  docs/specs/lsp.md: 0515c939262d
  docs/specs/mcp.md: eb9a936be6e7
  docs/specs/mouse.md: 9ddcdd15e5ad
  docs/specs/org.md: eacefd3dbd04
  docs/specs/packages.md: e9a16175b04a
  docs/specs/projects.md: fac9a61f6afa
  docs/specs/shared-buffers.md: edc911376d67
  docs/specs/start-screen.md: fca5951c17a6
  docs/specs/terminals.md: 7b43584e6e0e
  docs/specs/tree-sitter.md: 0f8ff7a1b057
  docs/specs/vim.md: 7a2641f5642e
  docs/specs/wasm-plugins.md: b62f9140ac75
---
# Baseline

The specs that describe what imp already did when efforts started being tracked, so `lore next` does not offer to plan them.

## Approach

Nothing to build: each linked spec was written to describe existing code. Freezing this effort records their versions; when one changes, `lore next` says so. A feature that changes one gets its own effort. A small fix that only edits one (a known gap removed) runs `lore freeze docs/efforts/baseline.md` in the same commit.

## Tasks

- [x] Built before efforts were tracked.
