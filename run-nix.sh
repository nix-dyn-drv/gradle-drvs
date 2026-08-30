#!/usr/bin/env bash
# Wrapper for invoking the patched Nix (NixOS/nix#15793, builder-rpc-v0 +
# dynamic-derivations) that this repo's mechanism requires, with all the
# NIX_CONFIG/store plumbing already set up.
#
# The system nix-daemon (e.g. Determinate Nix) does not support
# dynamic-derivations/builder-rpc-v0, so every build using this repo's
# mechanism must run through the patched Nix binary AND bypass the daemon
# via an alternate, non-daemon store. This script does both:
#
#   1. builds/resolves packages.<system>.patched-nix using the AMBIENT
#      system Nix (that build itself needs no special features),
#   2. re-execs into that patched Nix binary with:
#        - the required --extra-experimental-features / --extra-system-features
#        - --store 'local?root=<store dir>' (bypassing the daemon)
#        - --accept-flake-config (so this flake's own nixConfig applies)
#
# Usage:
#   ./run-nix.sh build '.#packages.x86_64-linux.smithy-cli' -L --no-link --print-out-paths
#   ./run-nix.sh run '.#packages.x86_64-linux.smithy-cli' -- --version
#   ./run-nix.sh eval '.#packages.x86_64-linux.smithy-cli.drvPath'
#
# Any `nix` subcommand and its flags may follow. NIX_STORE_ROOT overrides
# the default store location (a sibling `gradle-drvs-store/` next to this
# repo, kept out of git).
set -euo pipefail

repoRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
system="${NIX_SYSTEM:-$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null)}"
storeRoot="${NIX_STORE_ROOT:-${repoRoot}/../gradle-drvs-store}"

if [ $# -lt 1 ]; then
  echo "usage: $0 <nix-subcommand> [args...]" >&2
  exit 1
fi

mkdir -p "$storeRoot"

# Step 1: resolve the patched Nix build with whatever Nix is already on
# PATH -- this build needs no special experimental features itself.
patchedNix=$(
  nix build --no-link --print-out-paths \
    --accept-flake-config \
    "${repoRoot}#packages.${system}.patched-nix"
)

echo "using patched nix: $patchedNix" >&2
echo "using store: local?root=$storeRoot" >&2

# Step 2: re-exec into the patched Nix binary with the required
# experimental features / system features / alt store baked in.
exec "$patchedNix/bin/nix" \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command flakes' \
  --extra-system-features 'builder-rpc-v0' \
  --accept-flake-config \
  --store "local?root=${storeRoot}" \
  "$@"
