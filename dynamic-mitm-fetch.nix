# Dynamic-derivations replacement for nixpkgs' `mitm-cache.fetch { name; data; }`
# (see ~/nixpkgs/master/pkgs/by-name/mi/mitm-cache/fetch.nix).
#
# Same call signature and same output shape ($out/https/<host>/<path> tree of
# fetched files / synthesized text), but the decision of "which URLs to fetch,
# with which hash" is read and acted on *inside* a sandboxed build, not at Nix
# eval time. Each URL needing a real fetch becomes its own dynamically
# constructed fixed-output derivation (`nix derivation add` + `nix store
# submit-output`), built inside a `builder-rpc-v0` sandbox that otherwise has
# no network access — a genuinely fixed-output derivation still gets network
# access to verify its hash, which is the mechanism this whole experiment
# rests on (validated against ~/nixgg/dyn-drv/dyn-json-drv.nix and NixOS/nix's
# own tests/functional/dyn-drv/non-trivial-submitted.nix).
{
  pkgs ? import <nixpkgs> { },
  patchedNix,
  system ? pkgs.stdenv.hostPlatform.system,
}:
let
  shell = "${pkgs.bash}/bin/bash";
in
{
  name ? "deps",
  data, # { "<url>": { "hash": "sha256-..." } | { "text": "..." } | { "redirect": "<url>" } }
}:
let
  dataFile = builtins.toFile "${name}-data.json" (builtins.toJSON data);

  outer = derivation {
    name = "${name}.drv";
    inherit system;
    builder = shell;
    PATH = "${patchedNix}/bin:${pkgs.jq}/bin:${pkgs.bash}/bin:${pkgs.coreutils}/bin";

    requiredSystemFeatures = [ "builder-rpc-v0" ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";

    inherit dataFile;
    bashBin = "${pkgs.bash}/bin/bash";
    innerPath = "${pkgs.bash}/bin:${pkgs.coreutils}/bin:${pkgs.curl}/bin";
    cacertFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    srcBasenames = builtins.toJSON (
      map (p: baseNameOf "${p}") [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.cacert
      ]
    );

    args = [ "-c" (builtins.readFile ./dynamic-mitm-fetch-builder.sh) ];
  };
in
{
  inherit outer;
  result = builtins.outputOf outer.outPath "out";
}
