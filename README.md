# gradle-drvs

A small, self-contained proof of concept: bring Nix's experimental **Dynamic
Derivations** to a Gradle dependency-fetch pipeline. Instead of nixpkgs'
`gradle.fetchDeps` / `mitm-cache.fetch` deciding *which* Maven artifacts to
fetch (and instantiating one Nix derivation per file) at **eval time**, this
repo defers that decision into a sandboxed **build-time** script — one
dynamically-constructed, genuinely fixed-output derivation per artifact,
built inside an otherwise network-isolated `builder-rpc-v0` sandbox.

Tested against nixpkgs' real `smithy-cli` dependency lockfile (`deps.json`).

## Why this works: the core mechanism

A `builder-rpc-v0` sandbox has no network access by default. But Nix always
grants network access to a **genuinely fixed-output derivation** (one whose
output hash is already known, so Nix can verify the fetch against it) — even
one constructed dynamically, at build time, from inside that same sandbox.

So the outer derivation's builder, for every Maven artifact it needs (each
already has a known `sha256` from the lockfile):

1. computes the literal, statically-known output path via
   `nix-store --print-fixed-path sha256 <hex-hash> <name>` (not a
   placeholder — that's only for outputs whose path *isn't* known ahead of
   time),
2. constructs a small JSON derivation description with
   `"outputs": {"out": {"method": "flat", "hash": "sha256-<SRI>"}}` (the
   `hash` key, not just `hashAlgo`, is what makes this a *fixed*, not
   *floating*, output — floating outputs do **not** get network access),
3. hands it to `nix derivation add` (prints the new `.drv` path),
4. collects all such per-artifact drvs, builds one final "assembler" inner
   derivation (via `nix derivation add` again) that symlinks each into a
   `$out/https/<host>/<path>` tree — the same shape nixpkgs'
   `mitm-cache/fetch.nix` already produces,
5. `nix store submit-output`s the assembler as the outer derivation's own
   output.

The consumer resolves the whole thing with a single
`builtins.outputOf outer.outPath "out"`.

Entries that need no network (synthesized `maven-metadata.xml` text, or
`redirect` aliases) skip the fixed-output dance entirely — they're written
straight into a manifest file consumed by the assembler, since there's
nothing to prove a hash against.

## Files

- **`dynamic-mitm-fetch.nix`** — the reusable function. Signature-compatible
  with nixpkgs' `mitm-cache.fetch { name; data; }`; returns
  `{ outer, result }` where `result` is the drop-in `mitmCache` value.
- **`dynamic-mitm-fetch-builder.sh`** — the outer derivation's builder
  script (the actual dynamic-derivations logic).
- **`test-small.nix`** — standalone test, 3 synthetic entries (2 real fetches
  + 1 synthesized text), no Gradle involved.
- **`test-smithy-mitm.nix`** — integration test: reuses nixpkgs'
  `gradle.fetchDeps`'s existing eval-time JSON expansion unchanged (only its
  final fetch/assembly step, `mitm-cache.fetch`, is replaced), fed a real (or
  trimmed) `smithy-cli` `deps.json`.
- **`smithy-cli/package.nix`** + **`smithy-cli/deps.json`** — a full copy of
  nixpkgs' `smithy-cli` recipe with exactly one change: `mitmCache` is built
  via `dynamicMitmFetch` instead of `gradle.fetchDeps`. Exposed as
  `packages.<system>.smithy-cli` in the flake. This is the real end-to-end
  build (see "Verified so far" below) — not just a `mitmCache` unit test.
- **`deps-subset.json`** — trimmed real slice of `smithy-cli`'s `deps.json`
  (3 files: gson jar + poms) for fast iteration before running against the
  full ~600-artifact set.
- **`flake.nix`** — packages the patched Nix (`packages.<system>.patched-nix`,
  from `NixOS/nix#15793`), the library function
  (`lib.<system>.dynamicMitmFetch`), and the built package
  (`packages.<system>.smithy-cli`) for downstream use.

## Why a patched Nix is required

The `dynamic-derivations` experimental feature this relies on
(`builtins.outputOf`, `nix derivation add`, `nix store submit-output`,
`builder-rpc-v0`) is not fully implemented in mainline/Determinate Nix as of
this writing — in particular `nix store submit-output` isn't even a
recognized subcommand there. This flake pins and builds a patched Nix from
[NixOS/nix#15793](https://github.com/NixOS/nix/pull/15793) (same revision
already vetted by the sibling `~/nixgg` project) as `packages.<system>.patched-nix`.

Because the *system* nix-daemon doesn't support these features either, every
build under this mechanism must bypass it entirely via an alternate,
non-daemon store:

```sh
nix build --store 'local?root=/tmp/some-dir' \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command flakes' \
  --accept-flake-config \
  .#checks.x86_64-linux.small
```

(`--accept-flake-config` lets the flake's own `nixConfig` block auto-supply
the `builder-rpc-v0` system feature and `ca-derivations dynamic-derivations`
experimental features; pass them explicitly with `--extra-*` flags instead
if you'd rather not trust flake config.)

## Building and running smithy-cli

```sh
PATCHED=/nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48
STORE=/some/persistent/dir   # NOT inside this repo -- gitignored, ~2GB

"$PATCHED/bin/nix" build --store "local?root=$STORE" \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command flakes' \
  --accept-flake-config \
  '.#packages.x86_64-linux.smithy-cli' -L --no-link --print-out-paths
```

Running the result directly (`$STORE/nix/store/.../bin/smithy`) fails —
its wrapper script and Java's own RPATH bake in absolute `/nix/store/...`
paths that don't exist outside the alt store. `nix run` re-resolves and
executes correctly against the same alt store instead:

```sh
"$PATCHED/bin/nix" run --store "local?root=$STORE" \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command flakes' \
  --accept-flake-config \
  '.#packages.x86_64-linux.smithy-cli' -- --version
# -> 1.72.1

"$PATCHED/bin/nix" run --store "local?root=$STORE" \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command flakes' \
  --accept-flake-config \
  '.#packages.x86_64-linux.smithy-cli' -- validate some-model.smithy
```

## Using this from another flake

```nix
{
  inputs.gradle-drvs.url = "path:/path/to/gradle-drvs"; # or a git URL once pushed

  outputs = { self, nixpkgs, gradle-drvs }:
    let
      system = "x86_64-linux";
      dynamicMitmFetch = gradle-drvs.lib.${system}.dynamicMitmFetch;
    in
    {
      # e.g. inside an overridden package.nix:
      #   mitmCache = (dynamicMitmFetch { name = "my-deps"; data = expandedJson; }).result;
    };
}
```

`data` must already be in the same *expanded* shape `mitm-cache.fetch`
accepts: `{ "<url>": { "hash": "sha256-..." } | { "text": "..." } | { "redirect": "<url>" } }`.
Reuse nixpkgs' `gradle.fetchDeps { pkg; data; }` and read its `.data`
passthru attribute to get there from a compact lockfile — see
`test-smithy-mitm.nix` for the exact pattern.

## Verified so far

- Standalone 3-entry mechanism test: passes, byte-identical content vs.
  reference fetches.
- Real `smithy-cli` dependency subset (gson jar+poms, 3 files, see
  `deps-subset.json`): passes, hash matches nixpkgs' recorded `deps.json`
  hash exactly.
- **Full end-to-end `smithy-cli` build against the real, complete
  `deps.json`** (`smithy-cli/package.nix`, ~600 artifacts / ~1100 files):
  registration of all ~1100 dynamic fetch derivations completed in a few
  minutes, `mitm-cache`'s proxy-replay setup hook accepted the resulting
  tree with no changes needed, the real Gradle build ran
  (`:smithy-cli:shadowJar`, `:smithy-cli:test`), `BUILD SUCCESSFUL`,
  `versionCheckHook` confirmed `smithy --version` → `1.72.1`, and
  `smithy validate` against a real Smithy model succeeded
  ("Validated 243 shapes"). This is the full seam working, not just the
  `mitmCache` replacement in isolation.

## Known scope cuts / next steps

- Registration overhead at full scale (~1100 `nix derivation add` shell-outs)
  turned out to be acceptable for a one-off proof-of-concept build (a few
  minutes), but was not rigorously benchmarked — if this pattern needs to
  run routinely (e.g. in CI), the escape hatch nixgg already uses for an
  analogous problem is a persistent worker-protocol connection instead of
  shelling out per artifact.
- The build output only exists under the alt store (`local?root=...`), not
  the real multi-user Nix store — `nix copy --to local` needs root/daemon
  privileges this user doesn't have. `nix run --store 'local?root=...'`
  (see above) is the clean way to execute it regardless; a real deployment
  would substitute normally once the patched Nix is trusted more broadly
  (or once `dynamic-derivations` lands upstream).
- Generating `deps.json` itself dynamically (rather than consuming an
  existing one) is a different, larger problem — it needs real unrestricted
  network access to *discover* hashes, which points at Nix's
  `impure-derivations` feature instead of the fixed-output trick used here.
  Not attempted; a good candidate for a follow-up experiment.
