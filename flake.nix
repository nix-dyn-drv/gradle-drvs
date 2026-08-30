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

  # NixOS/nix PR #15793 ("builder-rpc-v0" + `nix store submit-output`),
  # pinned at the same revision nixgg already vetted. Track by rev (not a
  # moving branch) so this flake's patched Nix stays reproducible even
  # after the PR lands or is superseded upstream.
  inputs.nix-15793 = {
    url = "github:NixOS/nix/8307c48d25b90582c3e49999cee4a7a46495d2b7";
  };

  outputs =
    { self, nixpkgs, nix-15793 }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in
    {
      # The patched Nix build (builder-rpc-v0 / dynamic-derivations support).
      # The system nix-daemon almost certainly does NOT support this feature
      # set, so every consumer of this flake's `lib.dynamicMitmFetch` must
      # build/run under THIS Nix, via an alternate store
      # (`--store 'local?root=/some/dir'`) that bypasses the daemon
      # entirely -- see README.md.
      packages = forAllSystems (system: {
        patched-nix = nix-15793.packages.${system}.nix-cli or nix-15793.packages.${system}.default;
        default = self.packages.${system}.patched-nix;
        smithy-cli = nixpkgs.legacyPackages.${system}.callPackage ./smithy-cli/package.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          patchedNix = self.packages.${system}.patched-nix;
        };
      });

      # Reusable library function: a drop-in, dynamic-derivations-based
      # replacement for nixpkgs' `mitm-cache.fetch { name; data; }`.
      # Usage:
      #   dynamicMitmFetch = gradle-drvs.lib.${system}.dynamicMitmFetch;
      #   mitmCache = (dynamicMitmFetch { name = "my-deps"; data = expandedJson; }).result;
      lib = forAllSystems (system: {
        dynamicMitmFetch =
          import ./dynamic-mitm-fetch.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            patchedNix = self.packages.${system}.patched-nix;
            inherit system;
          };
      });

      # `nix flake check` / `nix build .#checks.<system>.small` runs the
      # standalone 3-entry test; requires the alt-store + experimental
      # feature dance documented in README.md, so these are not run by a
      # plain `nix flake check` on an unmodified daemon -- they're provided
      # as named, discoverable build targets instead.
      checks = forAllSystems (system: {
        small = (
          import ./test-small.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            patchedNix = self.packages.${system}.patched-nix;
          }
        ).result;
      });
    };
}
