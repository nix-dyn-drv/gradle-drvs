# Splitting a Gradle Compile into Dynamic Derivations

This document describes `gradle-split.nix`: splitting a Gradle
multi-module **compile** (not just dependency fetching) into
independently-built Nix derivations, dynamically constructed at build time.
See `NOTES.md` for a gotchas-focused writeup; this document focuses on the
build graph shape.

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

## The Nix derivation graph this produces

```
┌──────────────────────────────────────────────────────────────────┐
│ [Tier 0] outer derivation                                        │
│   text-hashed (outputHashMode="text"), builder-rpc-v0             │
│   builder script:                                                │
│     for each module (in dependency order, via recursion):        │
│       - compute input placeholder for each upstream module's      │
│         not-yet-built "out" (hand-rolled DownstreamPlaceholder    │
│         formula — see NOTES.md)                                  │
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
│          this being a fresh checkout in a fresh JVM (verified —   │
│          see NOTES.md)                                            │
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
  successfully through the full flake path (not just ad-hoc `-f` files).

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
