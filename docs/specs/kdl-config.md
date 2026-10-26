---
status: accepted
summary: "A declarative config.kdl loaded before init.scm, behind the kdl feature."
anchors: [runtime/config.scm, crates/imp-server/src/kdl.rs, crates/imp-server/tests/kdl.rs, examples/config.kdl]
---
# KDL config

An optional typed config alongside the live Scheme one, for reproducible settings. Off unless built with `--features kdl`.

## Behaviour

- `~/.config/imp/config.kdl` loads before `init.scm`, so Scheme can override it.
- Settings: `theme`, `option`, `options { ... }`, `key`, `keys STATE { ... }`, `leader`, `language-server`. Unknown nodes and bad values are reported with their line numbers; commands aren't checked, since `init.scm` may define them later.
- Without the feature, a `config.kdl` gets one message saying this build can't read it.
- Starter file: `examples/config.kdl`.
