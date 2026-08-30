# Integration test: replace smithy-cli's `mitmCache` (normally
# `gradle.fetchDeps { ... data = ./deps.json; }`) with the dynamic-derivations
# version. Reuses `gradle.fetchDeps`'s existing eval-time JSON expansion
# (decompression + maven-metadata.xml synthesis) unchanged -- only the final
# fetch/assembly step (normally `mitm-cache.fetch`) is replaced.
{
  pkgs ? import <nixpkgs> { },
  patchedNix ? builtins.storePath /nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48,
  # Path to a deps.json (or subset) to drive the test.
  depsFile ? /home/tbereknyei/nixpkgs/master/pkgs/by-name/sm/smithy-cli/deps.json,
}:
let
  dynamicMitmFetch = import ./dynamic-mitm-fetch.nix { inherit pkgs patchedNix; };

  fetchDeps = pkgs.callPackage ~/nixpkgs/master/pkgs/development/tools/build-managers/gradle/fetch-deps.nix { };

  # Force only `.data` (the expanded JSON, as a store path) -- this is a
  # separate thunk from `mitm-cache.fetch`'s own `code`/`fetchurl` machinery,
  # so reading it does not pay the eval-time cost we're trying to avoid.
  # `fetch-deps.nix` always forces `pkg.pname` for naming purposes, so we
  # hand it a synthetic package attrset rather than a real nixpkgs attrPath.
  expanded = fetchDeps {
    pkg = { pname = "smithy-cli-mitm-test"; };
    data = depsFile;
  };

  expandedData = builtins.fromJSON (builtins.readFile expanded.data);
in
dynamicMitmFetch {
  name = "smithy-cli-mitm-deps";
  data = builtins.removeAttrs expandedData [ "!version" ];
}
