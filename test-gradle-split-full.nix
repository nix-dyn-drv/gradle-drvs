# Full 6-module split of smithy-cli's build via gradle-split.nix:
#   smithy-utils (leaf)
#     -> smithy-model
#          -> smithy-build
#          -> smithy-diff
#          -> smithy-syntax (needs the "shadow" jar variant of syntax
#             per smithy-cli's build.gradle.kts, but the plain jar task
#             already produces a usable classes jar for this experiment)
#               -> smithy-cli
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
  name = "smithy-cli-modsplit";
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
    smithy-build = {
      deps = [ "smithy-model" ];
      task = ":smithy-build:jar";
      jarDir = "smithy-build";
    };
    smithy-diff = {
      deps = [ "smithy-model" ];
      task = ":smithy-diff:jar";
      jarDir = "smithy-diff";
    };
    smithy-syntax = {
      deps = [ "smithy-model" ];
      task = ":smithy-syntax:jar";
      jarDir = "smithy-syntax";
    };
    smithy-cli = {
      deps = [ "smithy-model" "smithy-build" "smithy-diff" "smithy-syntax" ];
      task = ":smithy-cli:jar";
      jarDir = "smithy-cli";
    };
  };
}
