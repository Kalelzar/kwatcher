#!/usr/bin/env bash
# Fleet-wide submodule bump + flake lock refresh in dependency order — thin
# wrapper over kw-nix's update-fleet.sh, which derives the graph from the
# submodule tree itself and also bumps the vendored pins (the previously
# manual step). COMMITS AND PUSHES in every package repo and the umbrella —
# run deliberately. See update-fleet.sh for flags (--dry-run, --no-build,
# --no-push, --init).
#
#   nix/update-all.sh [flags]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KW_NIX="${KW_NIX:-$HOME/Code/nix/kw-nix}"

exec "$KW_NIX/scripts/update-fleet.sh" "$@" "$ROOT"
