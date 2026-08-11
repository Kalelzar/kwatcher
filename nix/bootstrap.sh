#!/usr/bin/env bash
# One-shot flake bootstrap for the whole kw fleet. Idempotent: safe to re-run
# after a failure — locks no-op, builds hit the cache, commits are skipped
# when there is nothing staged, pushes are skipped when up to date.
#
#   nix/bootstrap.sh
#
# Prerequisites (yours): kw-nix committed and pushed to the forge; the
# previously-local packages (http-core, http-client, docgen-http-client)
# pushed and registered as submodules — inside the loop they are ordinary
# layer members.
#
# For every package repo in dependency order, then the umbrella: stage
# flake.nix, `nix flake lock`, TOFU the deps hash, `nix build`, commit the
# flake files, push. In the umbrella it additionally stages the submodule
# pins and the nix/ scripts.
#
# Only flake files (plus umbrella pins/scripts) are ever committed. Other
# uncommitted work is left alone — but a push publishes existing local
# commits on the branch, and dependents build against the PUSHED state, so
# commit in-flight work first if you want it included. The script warns per
# repo when it sees unrelated dirt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KW_NIX="${KW_NIX:-$HOME/Code/nix/kw-nix}"

# $HOME is itself a git repo: never run git in a directory that doesn't have
# its own .git, or the commands land in the wrong repository.
guard() {
  [ "$(git rev-parse --show-toplevel)" = "$PWD" ] \
    || { echo "!! $PWD is not its own git toplevel; refusing" >&2; exit 1; }
}

warn_dirt() {
  local dirt
  dirt="$(git status --porcelain | grep -vE ' (flake\.nix|flake\.lock|nix/|packages/)$' || true)"
  if [ -n "$dirt" ]; then
    echo "  !! uncommitted non-flake changes here (NOT included in the push):"
    echo "$dirt" | sed 's/^/     /'
  fi
}

commit_if_staged() {
  git diff --cached --quiet || git commit -m "$1"
}

do_repo() { # dir, commit-msg
  echo "=== $1"
  (
    cd "$1"
    guard
    warn_dirt
    git add flake.nix
    # `update`, not `lock`: lock only ADDS missing inputs and would leave a
    # lock from a previous partial run pinned to a stale kw-nix/dep rev.
    nix flake update --refresh
    git add flake.lock
    "$KW_NIX/scripts/update-deps-hash.sh" .
    nix build .#default --no-link --print-build-logs
    git add flake.nix flake.lock
    commit_if_staged "$2"
    # Submodules sit on detached HEADs and target master; the umbrella is on
    # a real branch (v2) and must push to THAT, never master.
    local branch
    branch="$(git symbolic-ref --short -q HEAD || echo master)"
    git fetch origin
    if git rev-parse --verify -q "origin/$branch" >/dev/null; then
      git rebase --autostash "origin/$branch"
    fi
    git push origin "HEAD:$branch"
  )
}

for dir in $(nix eval --json --file "$KW_NIX/lib/graph.nix" layers | jq -r '.[][]'); do
  do_repo "$ROOT/packages/$dir" "nix: add flake packaging"
done

(
  cd "$ROOT"
  guard
  git add packages nix/dev-build.sh nix/bootstrap.sh nix/update-all.sh
  commit_if_staged "chore: record package pins + nix scripts for flake bootstrap"
)
do_repo "$ROOT" "nix: add flake packaging"

echo
echo "Bootstrap complete. Enable homelab.kwRegistry in the infra repo, then:"
echo "  nix run kw-example"
