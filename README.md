# gradle-drvs

[![CI](https://github.com/nix-dyn-drv/gradle-drvs/actions/workflows/ci.yml/badge.svg)](https://github.com/nix-dyn-drv/gradle-drvs/actions/workflows/ci.yml)

Proof of concept for using Nix's experimental Dynamic Derivations with a
Gradle build. Normally, `gradle.fetchDeps` / `mitm-cache.fetch` decide
which Maven artifacts to fetch at eval time, instantiating one derivation
per file up front. Here that decision moves into a build-time script
instead: derivations are constructed dynamically inside a sandboxed build,
one per artifact.

Tested against nixpkgs' real `smithy-cli` package and its dependency
lockfile (`deps.json`).

## How it works

A `builder-rpc-v0` sandbox has no network access by default, but a
genuinely fixed-output derivation (hash known in advance) still gets
network access to verify its fetch, even if it was constructed dynamically
from inside that sandbox.

For each Maven artifact (hash already known from the lockfile), the outer
derivation's builder:

1. computes the artifact's output path with `nix-store --print-fixed-path`,
2. builds a JSON derivation description with
   `"outputs": {"out": {"method": "flat", "hash": "sha256-<SRI>"}}`,
3. registers it with `nix derivation add`,
4. once all artifacts are registered, builds one assembler derivation that
   symlinks them into a `$out/https/<host>/<path>` tree — the shape
   `mitm-cache/fetch.nix` already produces,
5. submits the assembler as its own output via `nix store submit-output`.

The consumer resolves this with `builtins.outputOf outer.outPath "out"`.
Entries that don't need network (synthesized `maven-metadata.xml`,
`redirect` aliases) skip the fixed-output step and go straight into a
manifest the assembler reads.

## Sharding the fetch

Registering ~1100 artifacts sequentially in one sandbox took 2m20s before
any fetch started. `lib/dynamic-mitm-fetch-sharded.nix` splits the artifact
list into N chunks, each its own outer derivation, so Nix's scheduler runs
the registration loops in parallel. Measured: 16-way sharding cuts it to
54s. `smithy-cli/package.nix` uses 16 shards by default.

## Splitting the compile itself

`lib/gradle-split.nix` applies the same idea to compiling: each Gradle
module in `smithy-cli`'s dependency graph (`smithy-utils` → `smithy-model`
→ `{build, diff, syntax}` → `cli`) becomes its own derivation, ordered by
real dependency edges instead of a network trick (compiling needs no
network once deps are cached).

Chaining compiles requires referencing an upstream derivation's not-yet-built
output — an input placeholder, in Nix's terms. `builtins.outputOf` can
normally compute this, but it isn't available from inside the sandbox that's
constructing the graph, so the placeholder formula is reimplemented directly
in the builder script (see `GRADLE-SPLIT.md`).

Incremental builds across these separate derivations come from Gradle's own
`--build-cache`: copying just the cache directory between independent
`gradle` invocations restores `FROM-CACHE` task results as if it were one
build. `GRADLE-SPLIT.md` has the full writeup, including a diagram of the
resulting derivation graph.

## Files

- `lib/dynamic-mitm-fetch.nix` + `-builder.sh` — the fetch mechanism.
  Drop-in replacement for `mitm-cache.fetch { name; data; }`.
- `lib/dynamic-mitm-fetch-sharded.nix` — splits the above across N
  independent derivations and merges the results.
- `lib/gradle-split.nix` + `-builder.sh` — the compile-split mechanism.
- `lib/primed-gradle-home.nix` — resolves a project's Gradle dependencies
  and exports just the cache, for per-module derivations to reuse.
- `tests/small.nix` — synthetic smoke test, no Gradle involved. Wired into
  `checks.<system>.small`.
- `tests/smithy-cli-modsplit.nix` — the full 6-module `smithy-cli` chain.
  Exposed as `packages.<system>.smithy-cli-modsplit`.
- `smithy-cli/package.nix` + `deps.json` — nixpkgs' `smithy-cli` recipe
  with one change: `mitmCache` uses `dynamicMitmFetchSharded` instead of
  `gradle.fetchDeps`. Exposed as `packages.<system>.smithy-cli`.
- `flake.nix` — packages the patched Nix, the library functions
  (`lib.<system>.dynamicMitmFetch`, `gradleSplit`, ...), and the built
  packages above.
- `run-nix.sh` — resolves the patched Nix and re-execs into it with the
  right store and feature flags already set. Use this instead of `nix`
  directly.
- `.github/workflows/ci.yml` — runs all three targets above on every
  push/PR.

## Why a patched Nix

`dynamic-derivations` (`builtins.outputOf`, `nix derivation add`,
`nix store submit-output`, `builder-rpc-v0`) isn't fully implemented in
mainline/Determinate Nix yet — `nix store submit-output` isn't even a
recognized subcommand there. This flake builds a patched Nix from
[NixOS/nix#15793](https://github.com/NixOS/nix/pull/15793) (same revision
the sibling `~/nixgg` project uses) as `packages.<system>.patched-nix`. It
substitutes from `cache.nixos.org`, so nothing needs to be compiled from
source.

The system nix-daemon doesn't support these features either, so builds
also need to bypass it via a non-daemon store. `run-nix.sh` handles both:

```sh
./run-nix.sh build '.#checks.x86_64-linux.small' -L --no-link --print-out-paths
```

That's equivalent to passing
`--extra-experimental-features 'ca-derivations dynamic-derivations nix-command flakes'`,
`--extra-system-features builder-rpc-v0`, `--accept-flake-config`, and
`--store 'local?root=<dir>'` directly.

## Building and running smithy-cli

```sh
./run-nix.sh build '.#packages.x86_64-linux.smithy-cli' -L --no-link --print-out-paths
```

The built binary can't be run directly — its wrapper script and Java's
RPATH reference absolute `/nix/store/...` paths that don't exist outside
the alt store. Use `nix run` instead, which re-resolves against the same
store:

```sh
./run-nix.sh run '.#packages.x86_64-linux.smithy-cli' -- --version
./run-nix.sh run '.#packages.x86_64-linux.smithy-cli' -- validate some-model.smithy
```

The store defaults to a sibling `../gradle-drvs-store/` (not in git,
~2GB) — override with `NIX_STORE_ROOT`.

## Using this from another flake

```nix
{
  inputs.gradle-drvs.url = "path:/path/to/gradle-drvs";

  outputs = { self, nixpkgs, gradle-drvs }:
    let
      system = "x86_64-linux";
      dynamicMitmFetch = gradle-drvs.lib.${system}.dynamicMitmFetch;
    in
    {
      # mitmCache = (dynamicMitmFetch { name = "my-deps"; data = expandedJson; }).result;
    };
}
```

`data` needs the same expanded shape `mitm-cache.fetch` accepts:
`{ "<url>": { "hash": "sha256-..." } | { "text": "..." } | { "redirect": "<url>" } }`.
`gradle.fetchDeps { pkg; data; }`'s `.data` output already produces this
from a compact lockfile — see `smithy-cli/package.nix`'s `mitmCache`
attribute.

## Verified

- `packages.smithy-cli`: real fetch of `smithy-cli`'s ~600 Maven artifacts,
  real Gradle build, `smithy --version` → `1.72.1`, `smithy validate`
  against a real model → `Validated 243 shapes`.
- `packages.smithy-cli-modsplit`: the same result, but built from 6
  separately-compiled module derivations. `smithy-model` restores
  `smithy-utils:compileJava` from cache; `smithy-cli` restores 8 of 13
  tasks from cache across its 4 upstream modules.
- Both run in CI on a plain `ubuntu-latest` runner (see `.github/workflows/ci.yml`).

## Known gaps

- Sharding helps, but 54s of registration overhead for ~1100 artifacts is
  still more than a static lockfile pays. A persistent worker-protocol
  connection (as nixgg uses for the same problem) would remove the
  per-artifact fork+exec cost, but isn't implemented here.
- Builds only exist under the alt store, not the real multi-user Nix
  store — copying into the real store needs root/daemon access this setup
  doesn't have. `nix run --store 'local?root=...'` works around it.
- `deps.json` itself is consumed as-is, not generated dynamically.
  Generating it would need real network access to discover hashes, which
  points at `impure-derivations` rather than the fixed-output trick used
  here — a different, larger problem, not attempted.
