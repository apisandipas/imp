---
type: Decision
status: accepted
anchors: ["Cargo.toml"]
---
# Crates follow the client/server boundary

## Context
The client/server split ([[0004-client-and-server]]) is only real if a client can't reach into server state.

## Decision
The workspace is split so the compiler enforces it: `imp-core` (shared types and the protocol), `imp-server` (the editor), `imp` (the binary and terminal client) and `imp-gui` (the window client, a library behind the `gui` feature). The owner confirmed the split, which began as three crates before the window client.

## Consequences
- Clients depend on `imp-core`, never on `imp-server` internals.
- A new client is a new crate against the same protocol.
