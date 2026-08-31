# Drop-in replacement for nixpkgs' mitm-cache.fetch { name; data; }: same
# call signature and output shape ($out/https/<host>/<path>), but which
# URLs to fetch is decided inside a sandboxed build instead of at eval
# time. Each URL becomes a dynamically-constructed fixed-output derivation
# -- a builder-rpc-v0 sandbox otherwise has no network access, but a
# genuinely fixed-output derivation still gets network access to verify
# its hash, which is what this relies on.
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
