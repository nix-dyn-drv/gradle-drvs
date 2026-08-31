# Splits a Gradle multi-module build into one dynamically-constructed
# derivation per module, chained via `inputs.drvs` + hand-resolved input
# placeholders (`builtins.outputOf`) so Nix builds upstream modules first --
# same builder-rpc-v0 + `nix derivation add` + `nix store submit-output`
# mechanism as dynamic-mitm-fetch.nix, but for compiling instead of
# fetching. Unlike fetching, compiling needs no network trick: each module
# derivation is an ordinary CAFloating (nar/sha256) output, ordered by real
# dependency edges instead of relying on fixed-output network access.
#
# Cross-module incrementality is achieved via Gradle's OWN build cache
# (--build-cache), seeded from the upstream module's cache dir (passed
# through the same inputs.drvs/outputOf mechanism) -- proven empirically
# (see GRADLE-SPLIT.md) that Gradle restores FROM-CACHE task outputs across
# completely independent JVM invocations sharing nothing but a cache
# directory and a primed dependency cache.
{
  pkgs ? import <nixpkgs> { },
  patchedNix,
  system ? pkgs.stdenv.hostPlatform.system,
}:
let
  shell = "${pkgs.bash}/bin/bash";
in
{
  name ? "gradle-modules",
  src,
  depsCache, # output of primed-gradle-home.nix
  # { "<module>": { deps = ["<upstream module>" ...]; task = "..."; jarDir = "<module>"; } }
  # task = the gradle task that produces this module's jar (e.g. ":smithy-model:jar").
  # jarDir = the module's subdirectory relative to src, whose build/libs/*.jar
  # gets collected into the final assembled output.
  modules,
}:
let
  modulesJson = builtins.toFile "${name}-modules.json" (builtins.toJSON modules);

  outer = derivation {
    name = "${name}.drv";
    inherit system;
    builder = shell;
    PATH = "${patchedNix}/bin:${pkgs.jq}/bin:${pkgs.bash}/bin:${pkgs.coreutils}/bin";

    requiredSystemFeatures = [ "builder-rpc-v0" ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";

    inherit modulesJson src depsCache;
    bashBin = "${pkgs.bash}/bin/bash";
    innerPath = "${pkgs.bash}/bin:${pkgs.coreutils}/bin:${pkgs.gradle}/bin:${pkgs.gnutar}/bin:${pkgs.findutils}/bin";
    srcBasenames = builtins.toJSON (
      map (p: baseNameOf "${p}") [
        pkgs.bash
        pkgs.coreutils
        pkgs.gradle
        pkgs.jdk21
        pkgs.gnutar
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
      ]
    );

    args = [ "-c" (builtins.readFile ./gradle-split-builder.sh) ];
  };
in
{
  inherit outer;
  result = builtins.outputOf outer.outPath "out";
}
