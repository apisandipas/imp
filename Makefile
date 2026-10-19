# Every build and test in one place. `make` lists the targets.
#
# Needs Rust (rustup.rs) and a C compiler. With Nix installed, cargo runs
# inside `nix develop` (the toolchain flake.lock pins) instead.
# Pass imp arguments with ARGS:
#   make run ARGS=src/main.rs
#   make dev-tui ARGS="--connect"

ARGS ?=
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
NIX := $(if $(IN_NIX_SHELL),,$(shell command -v nix 2>/dev/null))
CARGO := $(if $(NIX),nix develop -c cargo,cargo)

.DEFAULT_GOAL := help
.PHONY: help build build-tui run run-tui install install-tui uninstall \
        upgrade dev dev-tui test test-features test-all lint fmt fmt-check \
        check nix-build nix-install nix-install-tui nix-check ci bump clean

help: ## List the targets
	@grep -E '^(## |[a-z-]+:.*## )' $(MAKEFILE_LIST) | awk -F':.*## ' \
	  '/^## / { print "\n" substr($$0, 4); next } { printf "  make %-16s %s\n", $$1, $$2 }'

## Build and install (into ~/.local/bin; PREFIX=/usr/local for all users)

build: ## Optimized build into target/release/imp
	$(CARGO) build --release --locked -p imp-editor

build-tui: ## Optimized terminal-only build (no window) into target/release/imp
	$(CARGO) build --release --locked -p imp-editor --no-default-features

run: build ## Build and run imp (window when there's a display)
	target/release/imp $(ARGS)

run-tui: build ## Build and run imp in this terminal
	target/release/imp --tui $(ARGS)

install: build ## Build and install imp (PREFIX=~/.local)
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 target/release/imp $(DESTDIR)$(BINDIR)/imp

install-tui: build-tui ## Build and install the terminal-only imp
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 target/release/imp $(DESTDIR)$(BINDIR)/imp

uninstall: ## Remove the installed imp
	rm -f $(DESTDIR)$(BINDIR)/imp

upgrade: ## git pull, then build and install again
	git pull --ff-only
	$(MAKE) install

## Development (cargo; runtime/*.scm load from disk, no rebuild needed)

dev: ## Debug build, run with the window
	$(CARGO) run -- $(ARGS)

dev-tui: ## Debug build, run in this terminal
	$(CARGO) run -- --tui $(ARGS)

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

## Nix (optional)

nix-build: ## Build the Nix package into ./result
	nix build .#default

nix-install: ## Install imp into your Nix profile (on NixOS, use this)
	nix profile install .#default

nix-install-tui: ## Install the terminal-only imp into your Nix profile
	nix profile install .#tui

nix-check: ## The Nix package build, which runs the tests in a sandbox
	nix build -L .#default

ci: check nix-check ## What CI runs

## Releases

bump: ## Set the version: make bump VERSION=0.1.0-alpha.3
	@test -n "$(VERSION)" || { echo "usage: make bump VERSION=x.y.z"; exit 1; }
	sed -i.bak 's/^version = ".*"/version = "$(VERSION)"/' Cargo.toml
	sed -i.bak 's/version = "[^"]*";/version = "$(VERSION)";/' flake.nix
	rm -f Cargo.toml.bak flake.nix.bak
	$(CARGO) update --workspace -q
	@echo "Now: commit, git tag -a v$(VERSION) -m 'imp $(VERSION)', push main and the tag."

clean: ## Remove build output
	$(CARGO) clean
	rm -f result
