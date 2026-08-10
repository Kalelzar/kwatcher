#!/usr/bin/env bash
# Build any kw package (or the umbrella app) with Nix from the LOCAL working
# tree, without pushing anything: assembles a clean "fleet" of package
# sources in a scratch dir, generates path:-URL flake stubs there, and builds.
#
#   nix/dev-build.sh <dirName|umbrella> [extra nix build args...]
#
# Env: KW_NIX (kw-nix checkout, default ~/Code/nix/kw-nix)
#      FLEET  (scratch dir, default $TMPDIR/kw-fleet)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KW_NIX="${KW_NIX:-$HOME/Code/nix/kw-nix}"
FLEET="${FLEET:-${TMPDIR:-/tmp}/kw-fleet}"
target="${1:?usage: dev-build.sh <dirName|umbrella> [nix build args...]}"
shift || true

mkdir -p "$FLEET/_grafts" "$FLEET/umbrella"

# Clean copies of every package worktree (junk excluded; vendor/ kept — the
# initialized vendors also serve as local sources for the non-flake grafts).
for d in "$ROOT"/packages/*/; do
  n="$(basename "$d")"
  rsync -a --delete \
    --exclude .git --exclude .zig-cache --exclude zig-out --exclude result \
    "$d" "$FLEET/$n/"
done

# Local sources for the non-flake graft inputs, taken from the initialized
# umbrella vendors (zamqp includes its rabbitmq-c submodule checkout).
rsync -a --delete --exclude .git --exclude .zig-cache --exclude zig-out \
  "$ROOT/packages/amqp/vendor/zamqp/" "$FLEET/_grafts/zamqp/"
rsync -a --delete --exclude .git --exclude .zig-cache --exclude zig-out \
  "$ROOT/packages/amqp/vendor/zamqp/vendor/rabbitmq-c/" "$FLEET/_grafts/rabbitmq-c/"
rsync -a --delete --exclude .git --exclude .zig-cache --exclude zig-out \
  "$ROOT/packages/kwev/vendor/zstd/" "$FLEET/_grafts/zstd-wrapper/"
rsync -a --delete --exclude .git --exclude .zig-cache --exclude zig-out \
  "$ROOT/packages/orm-sqlite/vendor/sqlite3/" "$FLEET/_grafts/sqlite3/"

# Umbrella root: exactly the zon-declared paths, minus packages/.
for f in build.zig build.zig.zon .kw-workspace LICENSE; do
  [ -e "$ROOT/$f" ] && cp "$ROOT/$f" "$FLEET/umbrella/$f"
done
rsync -a --delete "$ROOT/src/" "$FLEET/umbrella/src/"
rsync -a --delete "$ROOT/migrations/" "$FLEET/umbrella/migrations/"

"$KW_NIX/scripts/gen-flakes.sh" --local "$FLEET" "$ROOT" >/dev/null

case "$target" in
  umbrella) dir="$FLEET/umbrella" ;;
  *) dir="$FLEET/$target" ;;
esac

# TOFU the external-deps hash first (also copies it back into the real stub
# so the eventual pushed flake carries the right hash).
"$KW_NIX/scripts/update-deps-hash.sh" "path:$dir"
if [ "$target" = umbrella ]; then
  real="$ROOT/flake.nix"
else
  real="$ROOT/packages/$target/flake.nix"
fi
if [ -f "$real" ] && grep -q 'depsHash = "sha256-' "$dir/flake.nix"; then
  hash="$(sed -n 's/.*depsHash = "\(sha256-[^"]*\)".*/\1/p' "$dir/flake.nix" | head -1)"
  sed -i "s|depsHash = \"sha256-[^\"]*\"|depsHash = \"$hash\"|" "$real" 2>/dev/null || true
fi

exec nix build "path:$dir#default" --no-write-lock-file --print-build-logs "$@"
