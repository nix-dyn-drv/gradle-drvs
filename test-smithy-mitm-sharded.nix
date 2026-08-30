# Sharded variant of test-smithy-mitm.nix: same real deps.json, but split
# across N independent outer sandboxes so Nix's scheduler can register
# artifacts in parallel instead of one long sequential loop.
{
  pkgs ? import <nixpkgs> { },
  patchedNix ? builtins.storePath /nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48,
  depsFile ? ./smithy-cli/deps.json,
  shards ? 8,
}:
let
  dynamicMitmFetchSharded = import ./dynamic-mitm-fetch-sharded.nix { inherit pkgs patchedNix; };

  expanded = pkgs.gradle.fetchDeps {
    pkg = { pname = "smithy-cli-mitm-test"; };
    data = depsFile;
  };

  expandedData = builtins.fromJSON (builtins.readFile expanded.data);
in
dynamicMitmFetchSharded {
  name = "smithy-cli-mitm-deps";
  inherit shards;
  data = builtins.removeAttrs expandedData [ "!version" ];
}
