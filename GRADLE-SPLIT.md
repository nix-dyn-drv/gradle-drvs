# Splitting a Gradle Compile into Dynamic Derivations

`dynamic-mitm-fetch.nix` demonstrates deferring *fetch* decisions into
build-time dynamic derivations. `gradle-split.nix` applies the same
mechanism to the **compile** step: each Gradle module in a multi-module
project becomes its own dynamically-constructed Nix derivation, chained by
real dependency edges, instead of one monolithic Gradle invocation.

## The module dependency graph (real, from `smithy-cli`)

Extracted from `smithy-lang/smithy`'s actual `build.gradle.kts`
`project(":...")` references (tag `1.72.1`):

```
smithy-utils   (leaf — no project() deps)
  │
  ▼
smithy-model   (api project(":smithy-utils"))
  │
  ├──────────────┬──────────────┐
  ▼              ▼              ▼
smithy-build  smithy-diff  smithy-syntax
  │              │              │
  └──────────────┴──────────────┘
                 │
                 ▼
            smithy-cli
   (implementation model, build, diff;
    implementation syntax, "shadow" variant)
```

Six modules, five edges. This is the whole graph `gradle-split.nix` is
told about via its `modules` argument — nothing more is discovered at
runtime; the "dynamism" is in *when* each module's derivation is
constructed and registered (at outer-build time), not in discovering the
graph shape itself. (A logical next step: have the outer builder run
`gradle :module:dependencies` or parse `settings.gradle.kts` itself to
discover this graph, instead of hardcoding it — not implemented here.)

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

## The Nix derivation graph this produces

```
┌──────────────────────────────────────────────────────────────────┐
│ [Tier 0] outer derivation                                        │
│   text-hashed (outputHashMode="text"), builder-rpc-v0             │
│   builder script:                                                │
│     for each module (in dependency order, via recursion):        │
│       - compute input placeholder for each upstream module's      │
│         not-yet-built "out" (hand-rolled DownstreamPlaceholder    │
│         formula — see above)                                      │
│       - `nix derivation add` a JSON drv for this module           │
│         · inputs.drvs = { <upstream module drvs> }                │
│         · builder script: seed GRADLE_USER_HOME + build-cache     │
│           dir from upstream placeholders, run                     │
│           `gradle :module:task --build-cache --offline`,          │
│           export cache dir + compiled jar                        │
│     - `nix derivation add` one final assembler drv                │
│       · inputs.drvs = { <every module drv> }                      │
│       · copies every module's jar into one flat $out              │
│     - `nix store submit-output` the assembler as this             │
│       derivation's own "out"                                     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼   (outer's output *is* the assembler's
                                   .drv path — Nix's trampoline goal
                                   chains: "build that instead")
┌──────────────────────────────────────────────────────────────────┐
│ [Tier 1] module derivations — one per Gradle module               │
│   (CAFloating, nar/sha256 — content depends on source, no         │
│   network needed once deps are cached)                           │
│                                                                    │
│        smithy-utils.drv  (no inputs.drvs — leaf)                  │
│              │                                                    │
│              ▼           (inputs.drvs = {smithy-utils.drv})       │
│        smithy-model.drv                                           │
│         ╱      │      ╲   (inputs.drvs = {smithy-model.drv},      │
│        ▼       ▼       ▼   each independently)                   │
│  smithy-build  smithy-diff  smithy-syntax                        │
│    .drv          .drv         .drv                                │
│         ╲         │         ╱                                     │
│          ╲        │        ╱   (inputs.drvs = {build, diff,       │
│           ▼       ▼       ▼      syntax, model}.drv)              │
│              smithy-cli.drv                                       │
│                                                                    │
│   Nix's ordinary scheduler builds smithy-build/diff/syntax in     │
│   PARALLEL (all three depend only on smithy-model, no edges       │
│   among themselves) — same as it would for any static derivation  │
│   graph with this shape.                                          │
│                                                                    │
│   Each module's builder:                                          │
│     1. copies primed-gradle-home.nix's dependency cache into a    │
│        fresh, writable $GRADLE_USER_HOME (must be writable —      │
│        Gradle extracts native libs / writes lock files)           │
│     2. copies every upstream module's build-cache dir (resolved   │
│        via the input placeholder from Tier 0) into a fresh        │
│        writable build-cache dir                                  │
│     3. runs `gradle -p src --init-script ... :module:task         │
│        --build-cache --offline --no-daemon`                       │
│        → Gradle restores upstream tasks FROM-CACHE using only     │
│          the copied build-cache dir + dependency cache, despite   │
│          this being a fresh checkout in a fresh JVM (verified      │
│          above)                                                   │
│     4. exports out/cache (this module's build-cache dir, for the  │
│        NEXT module to seed from) and out/jars (this module's      │
│        compiled jar, for the final assembler)                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ [Tier 2] assembler derivation                                     │
│   inputs.drvs = ALL SIX module drvs (build-ordering only —        │
│   this derivation's own script never looks up a store path        │
│   dynamically, since each module's placeholder is already          │
│   known/precomputed in Tier 0)                                    │
│   script: cp every module's out/jars/*.jar into one flat $out     │
│   → smithy-build-1.72.1.jar, smithy-cli-1.72.1.jar,               │
│     smithy-diff-1.72.1.jar, smithy-model-1.72.1.jar,              │
│     smithy-syntax-1.72.1.jar, smithy-utils-1.72.1.jar             │
└──────────────────────────────────────────────────────────────────┘
```

Compare this to the fetch mechanism's graph (`dynamic-mitm-fetch.nix`):
there, Tier 1 is N *independent* leaves (no edges among fetches) because
every artifact's hash is already known — dynamism there is purely about
deferring *construction*, not *ordering*. Here, Tier 1 has real edges,
because a module's compile genuinely depends on its upstream modules'
compiled output, and that output's content (hence hash) isn't known until
it's actually built. This is the harder, more general case: dynamically
discovering *and ordering* a dependency graph at build time, not just
fanning out independent work.

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

## What was verified

- `smithy-model.drv` restored `smithy-utils:compileJava` **FROM-CACHE**,
  despite `smithy-utils` and `smithy-model` being two separate Nix
  derivations, separate JVM processes, separate `$TMPDIR`s, sharing
  nothing but a copied build-cache directory.
- `smithy-cli.drv` restored **8 of 13 tasks FROM-CACHE** from its four
  upstream modules (`smithy-model`, `smithy-build`, `smithy-diff`,
  `smithy-syntax`), each built as an independent derivation.
- The assembled jar set is functionally identical to nixpkgs' monolithic
  `smithy-cli` build: `smithy --version` → `1.72.1`; `smithy validate`
  against a real Smithy model → `SUCCESS: Validated 243 shapes`.
- Exposed as `packages.<system>.smithy-cli-modsplit` in `flake.nix`; built
  successfully through the full flake path (not just ad-hoc `-f` files),
  and passes in CI.

## Why this matters (and its limits)

Same underlying thesis as the fetch-sharding work, taken one step further:
the *shape* of the build graph — which modules exist, in what order they
must build, how their outputs flow to each other — is something a running
build can compute and register with Nix, not something that has to be
fully known to the Nix evaluator ahead of time. Here that shape was still
hand-declared (the `modules` argument), so the honest scope is "proved the
mechanism generalizes from fetch-ordering to compile-ordering with real
dependency edges" — not "Gradle project structure is now auto-discovered."
That auto-discovery is a natural next step, not yet attempted.
