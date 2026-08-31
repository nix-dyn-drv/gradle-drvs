# Sharded variant of dynamic-mitm-fetch.nix: splits `data` into N disjoint
# chunks, each built as its own independent outer derivation, then merges
# the resulting $out/https/... subtrees.
#
# The unsharded version registers every artifact sequentially in one
# sandbox (`nix derivation add` is a fork+exec per artifact) -- at ~1100
# entries that loop alone took several minutes before any fetch started.
# Splitting into separate derivations lets Nix's scheduler run the
# registration loops in parallel instead.
#
# The merge is a plain (non-dynamic) derivation: shards are disjoint by
# construction, so there's never a path collision to resolve.
{
  pkgs ? import <nixpkgs> { },
  patchedNix,
  system ? pkgs.stdenv.hostPlatform.system,
}:
let
  dynamicMitmFetch = import ./dynamic-mitm-fetch.nix { inherit pkgs patchedNix system; };

  # Split an attrset into `n` roughly-equal-size chunks by key, in a
  # deterministic (input-order-independent -- sorted keys) way so re-runs
  # produce the same shards and thus hit the same cached fetch drvs.
  chunkAttrs =
    n: attrs:
    let
      keys = builtins.sort (a: b: a < b) (builtins.attrNames attrs);
      total = builtins.length keys;
      # ceil(total / n)
      chunkSize = (total + n - 1) / n;
      chunks = builtins.genList (
        i:
        let
          chunkKeys = builtins.filter (
            k: builtins.elem k (pkgs.lib.sublist (i * chunkSize) chunkSize keys)
          ) keys;
        in
        pkgs.lib.genAttrs chunkKeys (k: attrs.${k})
      ) n;
    in
    builtins.filter (c: c != { }) chunks;
in
{
  name ? "deps",
  data,
  shards ? 8,
}:
let
  chunks = chunkAttrs shards data;
  results = pkgs.lib.imap0 (i: chunk: (dynamicMitmFetch {
    name = "${name}-shard-${builtins.toString i}";
    data = chunk;
  }).result) chunks;
in
{
  inherit chunks results;
  result = pkgs.symlinkJoin {
    name = "${name}-merged";
    paths = results;
  };
}
