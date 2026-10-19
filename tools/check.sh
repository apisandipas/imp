#!/usr/bin/env bash
# Pre-commit checks: tests, clippy, fmt. Exits non-zero if any fail.
cd "$(dirname "$0")/.."
# With Nix, use the toolchain flake.lock pins; otherwise the cargo on PATH.
if [ -z "$IN_NIX_SHELL" ] && command -v nix >/dev/null; then
  shell=(nix develop -c bash -c)
else
  shell=(bash -c)
fi
"${shell[@]}" '
  out=$(cargo test -q 2>&1); t=$?
  echo "$out" | grep -E "test result|^error"
  # A panic message is on the lines after "panicked at".
  echo "$out" | grep -A2 -E "^---- |panicked"
  # The Phase 5 prototypes, behind features (docs/design/phase-5.md).
  out=$(cargo test -q -p imp-server --all-features 2>&1) || t=1
  echo "$out" | grep -A2 -E "FAILED|panicked|^error"
  # And imp built terminal-only, without the window client.
  c=$(cargo clippy -q --all-targets 2>&1; cargo clippy -q --all-targets --all-features 2>&1; cargo clippy -q -p imp-editor --no-default-features 2>&1)
  echo "$c" | tail -30
  cargo fmt --check >/dev/null 2>&1; f=$?
  [ $f -eq 0 ] && echo FMT-OK || echo FMT-FAIL
  [ $t -eq 0 ] && [ -z "$c" ] && [ $f -eq 0 ]
' 2>&1 | grep -v "Git tree"
exit ${PIPESTATUS[0]}
