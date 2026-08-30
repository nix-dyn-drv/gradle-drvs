# Standalone test: 3 synthetic entries (2 "hash" fetches + 1 "text" synthesis),
# no Gradle/deps.json involved. Exercises the dynamic-mitm-fetch mechanism in
# isolation.
{
  pkgs ? import <nixpkgs> { },
  patchedNix ? builtins.storePath /nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48,
}:
let
  dynamicMitmFetch = import ./dynamic-mitm-fetch.nix { inherit pkgs patchedNix; };
in
dynamicMitmFetch {
  name = "test-deps";
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
