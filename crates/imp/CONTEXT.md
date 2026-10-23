# imp (the binary)

Package `imp-editor`, binary `imp` ([[0009-the-name-imp]]). `main.rs` parses the command line and picks a client: the window (`imp_gui::run`) when `imp_gui::display_available()` (`$WAYLAND_DISPLAY` or `$DISPLAY`; on macOS, not over SSH) and its event loop can be built; otherwise, or with `--tui` or `--via`, the terminal client in this file (crossterm, styled spans) ([[0007-the-window-client-first]]).

- Window-only flags (`--font`, `--scale`, `--screenshot`…) are an error in the terminal.
- `cargo build --no-default-features` (and `nix build .#tui`) makes a terminal-only imp; `tools/check.sh` lints that build too.
- The version is the workspace version in `Cargo.toml` (and `flake.nix`); `imp --version` prints it.
