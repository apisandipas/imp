---
status: accepted
summary: "The screen imp shows when started without a file."
anchors: [runtime/start.scm, crates/imp-server/tests/start.rs]
---
# Start screen

## Behaviour

- At the top is imp's logo, `imp` on a command line with a `:` before it and a block cursor after, and under it the version and `Vim keys, Scheme all the way down`.
- Started without a file, imp shows recent files (picked by digit), projects (by letter) and a few commands. `i` goes to the empty buffer; `:start` shows it again.

## Keys and options

`start-screen` (`#f` turns it off), `recent-files-max`.
