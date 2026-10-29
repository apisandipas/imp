---
type: Page
spec: "[[spec/mcp]]"
frozen:
  docs/specs/mcp.md: eb9a936be6e7
---
# MCP

MCP lets an AI agent, such as Claude Code, work in the editor you're using. It gets the same access you have: your buffers, commands and ex commands. It's off until you turn it on.

## Turning it on

Add this to `init.scm`:

```scheme
(mcp-enable!)
```

The editor then listens on a socket only you can reach, `$XDG_RUNTIME_DIR/imp/mcp.sock`. An agent connects by running `imp --mcp` as its MCP server. For Claude Code:

```sh
claude mcp add imp -- imp --mcp
```

An agent with this access can evaluate Scheme, and so run anything you could. Turn it on only for agents you'd trust with your shell.

## What an agent can do

An agent can:

- List, read and edit buffers, including unsaved changes.
- Open files and save buffers.
- See where your cursor is, and move it.
- Search a buffer.
- Run a named command, or an ex command.
- Read the language servers' errors and warnings.
- Evaluate Scheme in the running editor.

## Watching what it does

Each change an agent makes shows on the status line, starting with `agent:`. `M-x mcp-log` lists them all. Each edit an agent makes is one undo step, so `u` takes it back.

## Adding a tool

`define-mcp-tool!` gives agents a tool of your own. It takes a name, a description, a JSON Schema for the arguments, and a procedure. The procedure gets the arguments and returns text.

```scheme
(define-mcp-tool! "word_count"
  "Count the words in the current buffer."
  (schema '() '())
  (lambda (args)
    (number->string (length (split-whitespace (buffer-substring 0 (buffer-length)))))))
```

`(schema '() '())` is a schema with no arguments.
