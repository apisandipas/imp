# Every build and test in one place. `make` lists the targets.
#
# Cargo targets run inside `nix develop` (the toolchain flake.lock pins)
# unless you're already in it. Pass imp arguments with ARGS:
#   make run ARGS=src/main.rs
#   make dev-tui ARGS="--connect"

ARGS ?=
CARGO := $(if $(IN_NIX_SHELL),cargo,nix develop -c cargo)

.DEFAULT_GOAL := help
.PHONY: help build build-tui run run-tui dev dev-tui release release-tui \
        install install-tui upgrade test test-features test-all lint fmt \
        fmt-check check nix-check ci bump clean

help: ## List the targets
	@grep -E '^(## |[a-z-]+:.*## )' $(MAKEFILE_LIST) | awk -F':.*## ' \
	  '/^## / { print "\n" substr($$0, 4); next } { printf "  make %-14s %s\n", $$1, $$2 }'

## Nix builds (what users get)

build: ## Build imp with the window into ./result
	nix build .#default

build-tui: ## Build the terminal-only imp into ./result
	nix build .#tui

run: ## Build and run imp (window when there's a display)
	nix run .#default -- $(ARGS)

run-tui: ## Build and run imp in this terminal
	nix run .#default -- --tui $(ARGS)

install: ## Install imp into your Nix profile
	nix profile install .#default

install-tui: ## Install the terminal-only imp into your Nix profile
	nix profile install .#tui

upgrade: ## Rebuild the imp in your Nix profile from this checkout
	nix profile upgrade imp

## Development (cargo; runtime/*.scm load from disk, no rebuild needed)

dev: ## Debug build, run with the window
	$(CARGO) run -- $(ARGS)

dev-tui: ## Debug build, run in this terminal
	$(CARGO) run -- --tui $(ARGS)

release: ## Optimized build into target/release/imp
	$(CARGO) build --release --locked

release-tui: ## Optimized terminal-only build into target/release/imp
	$(CARGO) build --release --locked -p imp-editor --no-default-features

## Tests and checks

test: ## Run the tests
	$(CARGO) test

test-features: ## Run the tests with the Phase 5 prototypes on (wasm, crdt, kdl)
	$(CARGO) test -p imp-server --all-features

test-all: test test-features ## Both of the above

lint: ## Clippy: default, all features, terminal-only
	$(CARGO) clippy --all-targets
	$(CARGO) clippy --all-targets --all-features
	$(CARGO) clippy -p imp-editor --no-default-features

fmt: ## Format the code
	$(CARGO) fmt

fmt-check: ## Check formatting
	$(CARGO) fmt --check

check: ## Everything to pass before a commit (tests, clippy, fmt)
	tools/check.sh

nix-check: ## The Nix package build, which runs the tests in a sandbox
	nix build -L .#default

ci: check nix-check ## What CI runs

## Releases

bump: ## Set the version: make bump VERSION=0.1.0-alpha.3
	@test -n "$(VERSION)" || { echo "usage: make bump VERSION=x.y.z"; exit 1; }
	sed -i 's/^version = ".*"/version = "$(VERSION)"/' Cargo.toml
	sed -i 's/version = "[^"]*";/version = "$(VERSION)";/' flake.nix
	$(CARGO) update --workspace -q
	@echo "Now: commit, git tag -a v$(VERSION) -m 'imp $(VERSION)', push main and the tag."

clean: ## Remove build output
	$(CARGO) clean
	rm -f result
