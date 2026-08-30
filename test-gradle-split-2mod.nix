# Minimal 2-module test of gradle-split.nix: smithy-utils (leaf) ->
# smithy-model (depends on smithy-utils). Uses the real primed dependency
# cache and real source, but only 2 of the 6 modules in the full chain, to
# keep iteration cheap while validating the mechanism.
{
  pkgs ? import <nixpkgs> { },
  patchedNix ? builtins.storePath /nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48,
}:
let
  dynamicMitmFetchSharded = import ./dynamic-mitm-fetch-sharded.nix { inherit pkgs patchedNix; };
  gradleSplit = import ./gradle-split.nix { inherit pkgs patchedNix; };

  expanded = pkgs.gradle.fetchDeps {
    pkg = { pname = "smithy-cli-split-test"; };
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

  depsCache = pkgs.callPackage ./primed-gradle-home.nix {
    inherit src mitmCache;
    gradleBuildTask = ":smithy-cli:shadowJar :smithy-cli:test";
  };
in
gradleSplit {
  name = "smithy-2mod";
  inherit src depsCache;
  modules = {
    smithy-utils = {
      deps = [ ];
      task = ":smithy-utils:jar";
      jarDir = "smithy-utils";
    };
    smithy-model = {
      deps = [ "smithy-utils" ];
      task = ":smithy-model:jar";
      jarDir = "smithy-model";
    };
  };
}
