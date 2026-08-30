# Sharded variant of dynamic-mitm-fetch.nix: splits `data` into N disjoint
# chunks and builds each chunk as its own independent outer derivation
# (i.e. its own builder-rpc-v0 sandbox running its own registration loop),
# then merges the resulting $out/https/... subtrees.
#
# Why: the unsharded version registers every artifact sequentially inside
# ONE outer sandbox (`nix derivation add` is a fork+exec per artifact) --
# at ~1100 entries (smithy-cli's real deps.json) that loop alone took
# several minutes before any fetch/build even started. Since each chunk's
# registration loop is independent, Nix's own scheduler can run up to
# `--max-jobs` of them in parallel once they're split into separate
# derivations -- this doesn't reduce total registration WORK, but it does
# reduce wall-clock time by however many outer sandboxes can run at once.
#
# The merge step is a PLAIN (non-dynamic) derivation: shards are disjoint
# by construction (each URL key lands in exactly one shard), so there is
# never a path collision to resolve, and `pkgs.symlinkJoin` is enough.
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
