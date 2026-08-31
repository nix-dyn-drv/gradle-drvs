{
  description = "Gradle-flavored proof of concept for Nix Dynamic Derivations: defer per-Maven-artifact fetch-derivation construction (normally done eagerly by nixpkgs' gradle.fetchDeps / mitm-cache.fetch) into a builder-rpc-v0 sandbox at build time, tested against nixpkgs' smithy-cli.";

  nixConfig = {
    extra-experimental-features = [
      "ca-derivations"
      "dynamic-derivations"
    ];
    extra-system-features = [ "builder-rpc-v0" ];
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # NixOS/nix PR #15793 (builder-rpc-v0 + `nix store submit-output`).
  # Pinned by rev so the patched Nix stays reproducible regardless of the
  # PR's upstream status.
  inputs.nix-15793 = {
    url = "github:NixOS/nix/8307c48d25b90582c3e49999cee4a7a46495d2b7";
  };

  outputs =
    { self, nixpkgs, nix-15793 }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in
    {
      packages = forAllSystems (system: {
        patched-nix = nix-15793.packages.${system}.nix-cli or nix-15793.packages.${system}.default;
        default = self.packages.${system}.patched-nix;
        smithy-cli = nixpkgs.legacyPackages.${system}.callPackage ./smithy-cli/package.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          patchedNix = self.packages.${system}.patched-nix;
        };
        # gradleSplit's `.result` is a raw builtins.outputOf string, not a
        # derivation (no .drvPath) -- wrap it so this is a normal package.
        smithy-cli-modsplit =
          let
            pkgs = nixpkgs.legacyPackages.${system};
            split = import ./tests/smithy-cli-modsplit.nix {
              inherit pkgs;
              patchedNix = self.packages.${system}.patched-nix;
            };
          in
          pkgs.runCommand "smithy-cli-modsplit" { } ''
            mkdir -p $out
            cp -r ${split.result}/* $out/
          '';
      });

      lib = forAllSystems (system: {
        dynamicMitmFetch =
          import ./lib/dynamic-mitm-fetch.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            patchedNix = self.packages.${system}.patched-nix;
            inherit system;
          };
        dynamicMitmFetchSharded =
          import ./lib/dynamic-mitm-fetch-sharded.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            patchedNix = self.packages.${system}.patched-nix;
            inherit system;
          };
        gradleSplit =
          import ./lib/gradle-split.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            patchedNix = self.packages.${system}.patched-nix;
            inherit system;
          };
      });

      checks = forAllSystems (system: {
        small = (
          import ./tests/small.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            patchedNix = self.packages.${system}.patched-nix;
          }
        ).result;
      });
    };
}
