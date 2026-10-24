---
type: Decision
status: accepted
anchors: [crates/imp-server/src/daemon.rs]
---
# Daemon clients own their windows and share the typing

## Context

Clients of `imp --daemon` shared one cursor and one window layout, like tmux sessions ([[daemon]], issue #3); only their sizes were their own. The owner wanted each client to have its own windows, as Emacs gives each `emacsclient` a frame. A client's state has two layers: the view, about twenty fields of the Rust `Editor` (layout, current window, cursor, scroll, window marks), and the interaction state, about 150 Scheme globals across ten runtime files (the mode, pending operator and count, the visual selection, the command line, menus, completion, macro recording, the jump list). Giving each client both would let two people type at once, but means saving and restoring every one of those globals around each event, and a rule that every new one be registered, or clients quietly leak state into each other. Giving each client only the view is one swap in Rust.

## Decision

Each daemon client owns its view: its window layout, current window, and each window's buffer, cursor and scroll, swapped into the `Editor` while that client's input is handled and its frame drawn. Everything else is shared, the typing state included, as for one person moving between clients; this is close to Emacs, where Evil's state belongs to the buffer, not the frame.

## Consequences

- Splits, scrolling and buffer switches in one client don't disturb another, and drawing one client's frame no longer re-scrolls the others.
- Two people can't type at once: keys from two clients mix in one mode and one command line. Separate sessions per client would supersede this decision.
- Code that keeps view state must keep it in the swapped `Editor` fields (or window ids), not in new Scheme globals, or it will be shared.
