#!/usr/bin/env bash
# Builds packages.<system>.patched-nix with the ambient system Nix, then
# re-execs into it with the store/feature flags this repo's mechanism needs
# (the system nix-daemon doesn't support dynamic-derivations/builder-rpc-v0,
# so builds must bypass it via a non-daemon store).
#
# Usage:
#   ./run-nix.sh build '.#packages.x86_64-linux.smithy-cli' -L --no-link --print-out-paths
#   ./run-nix.sh run '.#packages.x86_64-linux.smithy-cli' -- --version
#
# NIX_STORE_ROOT overrides the default store location (a sibling
# gradle-drvs-store/ next to this repo, kept out of git).
set -euo pipefail

repoRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
system="${NIX_SYSTEM:-$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null)}"
storeRoot="${NIX_STORE_ROOT:-${repoRoot}/../gradle-drvs-store}"

if [ $# -lt 1 ]; then
  echo "usage: $0 <nix-subcommand> [args...]" >&2
  exit 1
fi

mkdir -p "$storeRoot"

patchedNix=$(
  nix build --no-link --print-out-paths \
    --accept-flake-config \
    "${repoRoot}#packages.${system}.patched-nix"
)

echo "using patched nix: $patchedNix" >&2
echo "using store: local?root=$storeRoot" >&2

exec "$patchedNix/bin/nix" \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command flakes' \
  --extra-system-features 'builder-rpc-v0' \
  --accept-flake-config \
  --store "local?root=${storeRoot}" \
  "$@"
