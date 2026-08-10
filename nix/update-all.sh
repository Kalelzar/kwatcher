#!/usr/bin/env bash
# Fleet-wide lock refresh in dependency order — the convergence mechanism for
# per-repo flake lock skew. Run after changing any package (or kw-nix):
# every repo gets `nix flake update`, a re-TOFU of its external-deps hash if
# those changed, a build, and a commit+push when the flake files moved.
#
# NOTE: this script COMMITS AND PUSHES in each package repo — run deliberately.
#
#   nix/update-all.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KW_NIX="${KW_NIX:-$HOME/Code/nix/kw-nix}"

do_repo() {
  local dir="$1"
  echo "=== updating $dir"
  (
    cd "$dir"
    git pull --ff-only
    nix flake update
    "$KW_NIX/scripts/update-deps-hash.sh" .
    nix build .#default --no-link --print-build-logs
    if ! git diff --quiet -- flake.nix flake.lock; then
      git add flake.nix flake.lock
      git commit -m "nix: bump flake locks"
      git push
    else
      echo "    (no lock changes)"
    fi
  )
}

for dir in $(nix eval --json --file "$KW_NIX/lib/graph.nix" layers | jq -r '.[][]'); do
  do_repo "$ROOT/packages/$dir"
done

echo "=== umbrella"
echo "Bump the submodule pins first if package repos moved:"
echo "  git -C $ROOT add packages && git -C $ROOT commit -m 'chore: bump packages'"
do_repo "$ROOT"
