# Notes: splitting the Gradle compile itself

`dynamic-mitm-fetch.nix` demonstrates deferring *fetch* decisions into
build-time dynamic derivations. `gradle-split.nix` applies the same
mechanism to the *compile* step: each Gradle module becomes its own
dynamically-constructed derivation, chained by real dependency edges
instead of relying on the fixed-output/network trick (compiling needs no
network once dependencies are cached, so there's nothing to "unlock").

## The core problem: passing a not-yet-built output between derivations

The fetch mechanism only ever needed `builtins.placeholder "out"` (a
derivation's own not-yet-known output) and literal, precomputed paths for
fixed-output derivations. Chaining compiles needs a third thing: derivation
B needs to reference *derivation A's* not-yet-built output, where neither
A nor B's output hash is known in advance (a compiled jar's content depends
on the source, so it's an ordinary `nar`/`sha256` CAFloating output, not a
fixed one).

This is exactly what Nix calls an **input placeholder** (see
`~/nix/doc/manual/source/store/derivation/index.md`, "Placeholders"
section). `builtins.outputOf drv "out"` computes this from *outside* the
sandbox, but **`builtins.storePath` (needed to give a raw path string
enough context for `outputOf`) is blocked inside a `builder-rpc-v0`
sandbox** ("Operation 10 not allowed inside derivation") — so it can't be
used from the outer builder script that's actually constructing the graph.

The fix: reimplement the placeholder formula directly in the builder
script, following `DownstreamPlaceholder::unknownCaOutput` in
`~/nix/src/libstore/downstream-placeholder.cc`:

```
clearText = "nix-upstream-output:" + <drv's store-hash-part> + ":" + <drv name minus .drv>
placeholder = "/" + nix32(sha256(clearText))
```

In shell:
```sh
hex=$(printf '%s' "$clearText" | sha256sum | cut -d' ' -f1)
nix32=$(nix hash convert --from base16 --to nix32 --hash-algo sha256 "$hex")
placeholder="/$nix32"
```

Verified against `builtins.outputOf` computed *outside* the sandbox for
the same drv path — byte-identical. `nix hash convert` takes the hash as a
positional argument, not `--stdin` (that flag doesn't exist on this Nix
build).

## Cross-derivation incrementality: Gradle's own build cache

Splitting one Gradle invocation into N independent Nix derivations means N
independent JVM processes with nothing shared by default — no in-memory
task graph, no incremental-build state on disk (each derivation's builder
gets a fresh `$TMPDIR`). Verified empirically (outside Nix first, then
inside) that this doesn't matter: Gradle's own `--build-cache`, backed by a
plain local directory, restores compiled task outputs (`FROM-CACHE`) across
completely independent `gradle` invocations with a *fresh checkout* and a
*fresh `GRADLE_USER_HOME`* — the only things that need to carry over are
the build-cache directory itself and the dependency cache
(`caches/modules-2`, `caches/jars-9`).

So each module derivation:
1. copies the primed dependency cache (`primed-gradle-home.nix`'s output)
   into a fresh, writable `$GRADLE_USER_HOME` (Gradle needs to write native
   libs / lock files here even for a "read-only" cache — a real read-only
   mount fails with "Could not initialize native services").
2. copies every upstream module's build-cache directory (resolved via the
   placeholder mechanism above) into its own fresh build-cache dir.
3. runs `gradle ... --build-cache --offline` for just that module's task.
4. exports both its build-cache dir (`out/cache`, for the next module to
   seed from) and its actual compiled jar (`out/jars`, for the final
   assembler to collect).

## Gotchas

- **Gradle needs a writable `GRADLE_USER_HOME`**, even when only reading
  cached dependencies — it writes lock files (`modules-2.lock`,
  `jars-9.lock`) and extracts native libs on first touch. Copying a Nix
  store path in verbatim and using it directly fails with
  "Permission denied" / "Could not initialize native services". Always
  `cp -r` into `$TMPDIR` then `chmod -R u+w`.
- **Same for the build-cache directory** seeded from upstream modules —
  Gradle writes `build-cache.lock` there too.
- **The assembler's derivation name must equal the outer's name minus
  `.drv`** (same rule as `dynamic-mitm-fetch-builder.sh`) — since a module
  is registered under its own name (e.g. `smithy-model`), you cannot
  `submit-output` a module's drv directly as the outer's output unless
  that module happens to share the outer's name. A tiny final assembler
  derivation (own name = outer's name, `inputs.drvs` = every module drv)
  that copies each module's jars into one flat `$out` sidesteps this and
  also means the outer's output isn't tied to a single "final" module.
- **`primed-gradle-home.nix` must run the SAME task set the real recipe
  uses** (`gradleBuildTask`, not a generic "resolve everything" task) — a
  generic `nixDownloadDeps`-style task tries to resolve configurations
  (e.g. `spotbugs`) that were never captured in `deps.json` because
  upstream's own recipe never resolves them either, and fails.
- **`inputs.drvs` keys are basenames** (hash+name, e.g.
  `abc123...-smithy-model.drv`), same as `inputs.srcs` — not the bare
  module name.

## What this proves

Two independently-registered, independently-built Nix derivations
(`smithy-utils`, `smithy-model`) — sharing nothing but a copied build-cache
directory and dependency cache — reproduce the exact `FROM-CACHE` behavior
Gradle gives you *within* a single invocation. Scaled to the full 6-module
`smithy-cli` dependency graph (`smithy-utils` → `smithy-model` → `{build,
diff, syntax}` → `cli`), the resulting jar set is byte-for-byte
functionally equivalent to the monolithic build: `smithy --version` →
`1.72.1`, `smithy validate` → `SUCCESS: Validated 243 shapes`, from jars
compiled by 6 separate dynamically-constructed derivations instead of one
Gradle invocation.
