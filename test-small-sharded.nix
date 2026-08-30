# Standalone test for dynamic-mitm-fetch-sharded.nix: same 3 entries as
# test-small.nix, split across shards to confirm the partition/merge logic.
{
  pkgs ? import <nixpkgs> { },
  patchedNix ? builtins.storePath /nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48,
}:
let
  dynamicMitmFetchSharded = import ./dynamic-mitm-fetch-sharded.nix { inherit pkgs patchedNix; };
in
dynamicMitmFetchSharded {
  name = "test-deps";
  shards = 2;
  data = {
    "https://raw.githubusercontent.com/NixOS/nix/master/README.md" = {
      hash = "sha256-5zQ7fQCHY1R4YKoy+HpYDJWBkSPdB8nLP+mkfw0jwV8=";
    };
    "https://raw.githubusercontent.com/NixOS/nixpkgs/master/README.md" = {
      hash = "sha256-/gWOOyjqLzSr2BZRehbW9EusC2iVaq3j9mynfK1uLCA=";
    };
    "https://example.org/maven-metadata.xml" = {
      text = "<?xml version=\"1.0\"?><metadata><groupId>example</groupId></metadata>\n";
    };
  };
}
