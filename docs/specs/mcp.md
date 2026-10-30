---
status: accepted
summary: "MCP: AI agents use the editor's buffers and commands, opt-in."
anchors: [runtime/mcp.scm, crates/imp-server/tests/mcp.rs]
---
# MCP

An agent gets the same access as a human: Emacs's "everything is a command" suits it.

## Behaviour

- Off by default. `(mcp-enable!)` in `init.scm` makes the editor listen on a socket private to the user (`$XDG_RUNTIME_DIR/imp/mcp.sock`); an agent runs `imp --mcp` as its stdio MCP server (`claude mcp add imp -- imp --mcp`).
- Tools: list, read and edit buffers, open, save, get and set the cursor, search, run a command, run an ex command, diagnostics, evaluate Scheme. More with `define-mcp-tool!`.
- Agent changes show on the status line ("agent: ...") and in `M-x mcp-log`; each edit is one undo step.

## Keys and options

- `(mcp-enable!)`, `(define-mcp-tool! "name" "description" schema handler)`.
