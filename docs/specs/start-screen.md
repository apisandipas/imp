---
status: accepted
summary: "The screen imp shows when started without a file."
anchors: [runtime/start.scm, crates/imp-server/tests/start.rs]
---
# Start screen

## Behaviour

- Started without a file, imp shows recent files (picked by digit), projects (by letter) and a few commands. `i` goes to the empty buffer; `M-x start-screen` shows it again.

## Keys and options

`start-screen` (`#f` turns it off), `recent-files-max`.
