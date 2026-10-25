---
type: Page
spec: "[[spec/kdl-config]]"
frozen:
  docs/specs/kdl-config.md: ed960468150c
---
# KDL config

`config.kdl` holds settings as plain data: a theme, options, keys and language servers. It sits beside `init.scm`, for settings you want to keep the same everywhere. It's optional, and only read by an imp built with `--features kdl`.

## Writing config.kdl

Put it at `~/.config/imp/config.kdl`. Each entry is one setting:

```kdl
theme "gruvbox-dark"

options {
    number #true
    relativenumber #true
    tabstop 4
    clipboard "unnamedplus"
}

keys "normal" {
    "C-s" "save-buffer"
}

leader "fs" "save-buffer" "save"

language-server "python-mode" "pylsp" markers=".git pyproject.toml" language="python"
```

| Setting | What it does |
|---|---|
| `theme NAME` | Load a theme |
| `option NAME VALUE` | Set one option |
| `options { NAME VALUE ... }` | Set several options |
| `key STATE KEYS COMMAND` | Bind a key in a state, such as `"normal"` |
| `keys STATE { KEYS COMMAND ... }` | Bind several keys in one state |
| `leader KEYS COMMAND [LABEL]` | Bind a key after `SPC`, with an optional label for the menu |
| `language-server MODE COMMAND` | Start a language server for a major mode; `markers=` and `language=` are optional |

imp's source has a starter file to copy, `examples/config.kdl`.

## How it fits with init.scm

`config.kdl` loads first, then `init.scm`. Anything `init.scm` sets wins.

A setting imp doesn't know, or a bad value, is reported on the message line with its line number. The rest of the file still loads. Command names aren't checked, since `init.scm` may define them later.

An imp built without the feature shows one message saying it can't read `config.kdl`.
