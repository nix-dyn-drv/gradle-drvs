# Standalone test for primed-gradle-home.nix: resolves all of smithy-cli's
# real Gradle dependencies (via the existing sharded mitmCache) with no
# compilation, exporting just the dependency cache.
{
  pkgs ? import <nixpkgs> { },
  patchedNix ? builtins.storePath /nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48,
}:
let
  dynamicMitmFetchSharded = import ./dynamic-mitm-fetch-sharded.nix { inherit pkgs patchedNix; };

  expanded = pkgs.gradle.fetchDeps {
    pkg = { pname = "smithy-cli-gradle-home-test"; };
    data = ./smithy-cli/deps.json;
  };
  expandedData = builtins.fromJSON (builtins.readFile expanded.data);

  mitmCache = (dynamicMitmFetchSharded {
    name = "smithy-cli-deps";
    shards = 16;
    data = builtins.removeAttrs expandedData [ "!version" ];
  }).result;

  src = pkgs.fetchFromGitHub {
    owner = "smithy-lang";
    repo = "smithy";
    tag = "1.72.1";
    hash = "sha256-IBqh2ATKi5MfaCjvXz7KE2p3lGJa8Sn3YhOuwaW1/sk=";
  };
in
pkgs.callPackage ./primed-gradle-home.nix {
  inherit src mitmCache;
  gradleBuildTask = ":smithy-cli:shadowJar :smithy-cli:test";
}
