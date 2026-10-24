---
type: Effort
status: done
specs: ["[[spec/buffers-and-windows]]", "[[spec/claude]]", "[[spec/completion-at-point]]", "[[spec/completion]]", "[[spec/daemon]]", "[[spec/dap]]", "[[spec/dired]]", "[[spec/emacs-state]]", "[[spec/files]]", "[[spec/folding]]", "[[spec/git]]", "[[spec/kdl-config]]", "[[spec/live-scheme-and-help]]", "[[spec/look]]", "[[spec/lsp]]", "[[spec/mcp]]", "[[spec/mouse]]", "[[spec/org]]", "[[spec/packages]]", "[[spec/projects]]", "[[spec/shared-buffers]]", "[[spec/start-screen]]", "[[spec/terminals]]", "[[spec/tree-sitter]]", "[[spec/vim]]", "[[spec/wasm-plugins]]"]
frozen:
  docs/specs/buffers-and-windows.md: 5493c6bda7d6
  docs/specs/claude.md: 580fb164d4a1
  docs/specs/completion-at-point.md: 7a992144e52e
  docs/specs/completion.md: c12abe1827ac
  docs/specs/daemon.md: e9b6075bb66b
  docs/specs/dap.md: b1a36380474b
  docs/specs/dired.md: a02aeaac49d8
  docs/specs/emacs-state.md: 335f67ba2c18
  docs/specs/files.md: b08542837535
  docs/specs/folding.md: b3202e83704a
  docs/specs/git.md: 7678e2b50569
  docs/specs/kdl-config.md: ed960468150c
  docs/specs/live-scheme-and-help.md: 32a20a367cfe
  docs/specs/look.md: 5b06abff64ec
  docs/specs/lsp.md: 39c97f93c037
  docs/specs/mcp.md: e74de57e9621
  docs/specs/mouse.md: 9395bb30b70d
  docs/specs/org.md: dcdec38aa573
  docs/specs/packages.md: 00303fd4a641
  docs/specs/projects.md: fac9a61f6afa
  docs/specs/shared-buffers.md: edc911376d67
  docs/specs/start-screen.md: 3d569d3bf3ea
  docs/specs/terminals.md: 6af137bb3cc1
  docs/specs/tree-sitter.md: 240b71980c1d
  docs/specs/vim.md: 5b67a0ac656c
  docs/specs/wasm-plugins.md: b62f9140ac75
---
# Baseline

The specs that describe what imp already did when efforts started being tracked, so `lore next` does not offer to plan them.

## Approach

Nothing to build: each linked spec was written to describe existing code. Freezing this effort records their versions; when one changes, `lore next` says so. A feature that changes one gets its own effort. A small fix that only edits one (a known gap removed) runs `lore freeze docs/efforts/baseline.md` in the same commit.

## Tasks

- [x] Built before efforts were tracked.
