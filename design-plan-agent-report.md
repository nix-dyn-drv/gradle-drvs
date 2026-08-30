# Implementation Plan: Dynamic Mitm-Cache for Gradle Dependencies via Dynamic Derivations

*(Report from the background Plan agent, "Design Gradle dynamic-derivations implementation plan". Saved verbatim for reference; the plan actually acted on is `/home/tbereknyei/.claude/plans/examine-nixgg-nix-drowse-zesty-pelican.md`.)*

## 0. Grounding from this session's exploration

I read the following to anchor every claim below in actual code (not just the background you gave me):

- `/home/tbereknyei/nixpkgs/master/pkgs/by-name/mi/mitm-cache/fetch.nix` — the function being replaced.
- `/home/tbereknyei/nixpkgs/master/pkgs/by-name/mi/mitm-cache/setup-hook.sh` and `package.nix` — confirms the consumer side only cares that `$mitmCache` is a directory (`[ -d "$mitmCache" ]`), then runs `mitm-cache -l"$ADDR" replay "$mitmCache"`. **No passthru attribute is read.** `passthru.data` (in `fetch.nix:70-73`) and `fetch-deps.nix`'s `passthru.updateScript` (gated by `lib.optionalAttrs (!builtins.isAttrs data)`) are purely for introspection/update tooling, never touched by the build or the setup hook. **Confirmed not load-bearing for a basic `nix build`.**
- `/home/tbereknyei/nixpkgs/master/pkgs/development/tools/build-managers/gradle/fetch-deps.nix` and `default.nix` — confirms `gradle.fetchDeps` does the `visit`/`visitAttrs`/`decompressNameVer`/`parseArtifactUrl`/XML-synthesis work in Nix language, then calls `mitm-cache.fetch { name; data = finalData // { "!version" = 1; }; }` — `data` here is an **already-expanded in-memory attrset**, not a path.
- `/home/tbereknyei/nixpkgs/master/pkgs/by-name/sm/smithy-cli/deps.json` and `package.nix` — measured directly: **600 artifact/version groups, 1097 file entries** total (46 artifacts/90 files under `plugins.gradle.org/m2`, 554 artifacts/1007 files under `repo.maven.apache.org/maven2`). `package.nix:36-39` sets `mitmCache = gradle.fetchDeps { inherit (finalAttrs) pname; data = ./deps.json; };` — this is the one line we need to override.
- `/home/tbereknyei/nix/src/libstore/derivation/json.cc`, `content-address.cc`, `hash.cc` — read the actual JSON (de)serializer for `DerivationOutput` in the patched Nix. This corroborates, from source, everything the empirical validation already established:
  - A `DerivationOutput` JSON object with **exactly** the keys `{"method","hash"}` is parsed as `CAFixed` (fixed-output). `"hash"` is parsed via `Hash::parseSRI` (`hash.cc:522-526`) — **must be SRI form** (`sha256-<base64>`), confirming the "not SRI" error and its fix.
  - `{"method","hashAlgo"}` (no `"hash"`) is `CAFloating` — this is the case that does **not** get network access, matching the validated finding.
  - `ContentAddressMethod::render()`/`parse()` (`content-address.cc:25-94`) confirms `"flat"` and `"text"` are the literal method strings; `"flat"` is correct for a single-file output like a jar/pom.
- `~/nixgg/dyn-drv/config.nix`, `dyn-json-drv.nix`, `dyn-one-layer.nix`, `NOTES.md`, and `~/nix/tests/functional/dyn-drv/non-trivial-submitted.nix` — the exact templates reused (outer text-hashed wrapper, `nix derivation add` in a loop building a DAG of inner drvs referencing each other via `inputs.drvs`, one final `submit-output`).
- `~/nixgg/ARCHITECTURE.md:443-557` — real measured numbers from a closely related project (nixgg) used directly for the risk section:
  - `nix derivation add`/`nix store add --scan`/`nix store submit-output` shelled out cost **~20-90ms/call** depending on load.
  - A hard Linux ceiling: a single `bash -c` argv string is capped at `MAX_ARG_STRLEN = 131072` bytes (measured exactly: 131072 fails, 131000 succeeds) — independent of `ARG_MAX`. Directly relevant to the assembler's builder script (see §4).
- Live-tested on this machine with the patched Nix at `/nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48`:
  ```
  $ nix hash convert --to base16 --hash-algo sha256 "sha256-r97W5qaQ+/OtSuZa2jl/CpCl9jCzA9G3QbnJeSb91N4="
  afded6e6a690fbf3ad4ae65ada397f0a90a5f630b303d1b741b9c97926fdd4de

  $ nix-store --print-fixed-path sha256 afded6e6a690fbf3ad4ae65ada397f0a90a5f630b303d1b741b9c97926fdd4de gson-2.8.9.pom
  /nix/store/ivwr7pcbngilvlifq0vpvasrvg74sgpy-gson-2.8.9.pom
  ```
  This is the literal, verified two-step sequence the outer builder must run for every "hash" entry in `deps.json`.
- `nix-build '<nixpkgs>' -A pkgsStatic.curl` → `/nix/store/rx8m5m20hz9idbcb7qbp9xq6k3bvhwkb-curl-static-x86_64-unknown-linux-musl-8.20.0-bin`, single output, no runtime `.so` deps (checked via `nix-store -q --references` on the dynamic build: 21 requisites vs the static build's effectively self-contained closure). Recommend the **static** curl for the inner fetch derivations specifically to keep each inner derivation's `inputs.srcs` list short (bash + coreutils + curl-static + cacert, 4 entries, instead of curl's full dynamic-linking closure).
- `nss-cacert` → `/nix/store/zdl7dn1gmi1cxdw5a8hw6xsf4cz0rjmg-nss-cacert-3.123/etc/ssl/certs/ca-bundle.crt`, needed for `SSL_CERT_FILE`.

## 1. Scope decision: keep JSON expansion in Nix, replace only `mitm-cache.fetch`'s internals

**Recommendation: do not touch `gradle.fetchDeps` at all.** Reasons:

- `gradle.fetchDeps`'s `visit`/`visitAttrs`/`decompressNameVer`/`parseArtifactUrl`/XML-synthesis logic is comparatively cheap **string/attrset manipulation** over 600 groups — no derivations are instantiated during this phase. The genuinely expensive, "why do this eagerly" part is specifically inside `mitm-cache/fetch.nix`'s `code` builder: the `lib.mapAttrsToList` over `data'` that calls `fetchurl { url; hash; }` or `writeText name val` **once per file entry** (~1097 times for smithy-cli), each of which is a full derivation-attrset construction. That's the part whose cost should be deferred to build time.
- Reusing `gradle.fetchDeps` unchanged is also a nice consequence of Nix's laziness: `mitm-cache.fetch`'s `passthru.data = writeText "deps.json" (builtins.toJSON data)` (`fetch.nix:70-73`) is a **separate thunk** from `code` (the expensive `mapAttrsToList` over `fetchurl`/`writeText`). If we only ever force `.data`, Nix never evaluates `code`'s 1097 `fetchurl`/`writeText` derivation constructions. This means: **`(gradle.fetchDeps { inherit pname; data = ./deps.json; }).data` already gives the fully-expanded, decompressed JSON (all URLs, all `hash`/`text`/`redirect` keys resolved) as a store path, for free, without paying the cost being avoided.** No code path was found that would force `code` as a side effect of reading `.data` — they're independent attrs of the same `runCommand` call's result attrset.
- This makes the smallest possible surgical change: **only `mitm-cache/fetch.nix`'s per-URL `fetchurl`/`writeText` construction + the `runCommand` symlink-assembly gets replaced.** Everything upstream (deps.json → expanded JSON) is untouched, battle-tested nixpkgs code.

Signature-parity with `mitm-cache.fetch`:

```nix
dynamicMitmCacheFetch =
  { name ? "deps", data, dontFixup ? true, ... }@attrs:
  ...
```

accepting `data` as either a path (`lib.importJSON`) or an already-expanded attrset — mirroring `fetch.nix:16`'s `data' = removeAttrs (if builtins.isPath data then lib.importJSON data else data) [ "!version" ]`.

Within that scope, recommend **not** dynamically constructing a per-file inner derivation for `"text"` (synthesized `maven-metadata.xml`) or `"redirect"` entries. Those already have fully-known content/target at outer-build time (no network dependency) — running `nix derivation add` for already-known static text doesn't demonstrate anything new; it only adds shell-out latency. **Only `"hash"` entries (jar/pom/module — the ones needing a real network fetch) go through the per-file `nix derivation add` + curl dance.** `"text"` and `"redirect"` entries are written/symlinked directly by the assembler's own builder script from the same parsed JSON.

## 2. Files to create in `~/gradle-drvs`

1. **`config.nix`** — copy/adapt `~/nixgg/dyn-drv/config.nix`'s `mkDerivation` helper (bash+coreutils PATH, not stdenv), extended with `jq`, `curl` (static), `cacert` on the outer's PATH, and the patched-nix path.
2. **`dynamic-mitm-cache.nix`** — the main deliverable (outer wrapper derivation, see §3).
3. **`test-small.nix`** — standalone unit test: 3-5 synthetic `{url, hash}` pairs.
4. **`smithy-cli/package.nix`** — copy of upstream `package.nix` with one line changed (`mitmCache` override).
5. **`smithy-cli/deps.json`** + **`deps-subset.json`** (hand-trimmed representative slice for cheap Phase 2 testing).
6. **`NOTES.md`** — gotchas log, mirroring `~/nixgg/dyn-drv/NOTES.md`'s style.

## 3. Exact derivation shapes

### 3a. Outer wrapper derivation

```nix
outer = derivation {
  name = "${name}.drv";
  system = builtins.currentSystem;
  builder = cfg.shell;
  PATH = "${patchedNix}/bin:${cfg.path}";
  requiredSystemFeatures = [ "builder-rpc-v0" ];
  __contentAddressed = true;
  outputHashMode = "text";
  outputHashAlgo = "sha256";
  expandedJson = expandedJson;
  curlBin      = "${pkgs.pkgsStatic.curl}/bin/curl";
  cacertFile   = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  bashPath     = cfg.bash;
  coreutilsPath = cfg.coreutils;
  curlPath     = pkgs.pkgsStatic.curl;
  cacertPath   = pkgs.cacert;
  args = [ "-c" (builtins.readFile ./outer-builder.sh) ];
};
```

Outer builder script logic (`outer-builder.sh`):
- One `jq` pass converts the expanded JSON into TSV rows (kind, url, value) — a single subprocess for the whole file, not one per entry.
- For each `hash` row: convert SRI→hex, `nix-store --print-fixed-path` to get the literal output path, build the per-file FOD JSON, `nix derivation add`, append `fetch\t<destPath>\t<drvPath>\t<outPath>` to a manifest.
- For `text`/`redirect` rows: append directly to the manifest without constructing any inner derivation.
- Write the manifest to the store via `nix store add --mode flat`.
- Build the assembler's `inputs.drvs` map from the manifest's `fetch` rows (keyed by `.drv` path, for build-ordering only).
- `nix derivation add` the assembler, then `nix store submit-output` it.

**Key correction the agent flagged**: the manifest's `fetch` rows must carry the **output path** (from `--print-fixed-path`), not just the `.drv` path — the assembler symlinks directly to that literal, statically-known output path. The `.drv` path is used *only* to populate `inputs.drvs` (the build-ordering dependency edge), never read by the assembler's script itself.

### 3b. Per-file fetch inner derivation (constructed ~600 times)

```json
{
  "name": "gson-2.8.9.pom",
  "system": "x86_64-linux",
  "builder": "/nix/store/<hash>-bash-5.3p9/bin/bash",
  "args": ["-c", "set -e; /nix/store/<hash>-curl-static-.../bin/curl -sSfL --cacert /nix/store/<hash>-nss-cacert-.../etc/ssl/certs/ca-bundle.crt -o \"$out\" \"https://repo.maven.apache.org/maven2/com/google/code/gson/gson/2.8.9/gson-2.8.9.pom\""],
  "env": {
    "out": "/nix/store/ivwr7pcbngilvlifq0vpvasrvg74sgpy-gson-2.8.9.pom",
    "SSL_CERT_FILE": "/nix/store/<hash>-nss-cacert-.../etc/ssl/certs/ca-bundle.crt",
    "PATH": ""
  },
  "inputs": {
    "drvs": {},
    "srcs": [
      "<hash>-bash-5.3p9",
      "<hash>-coreutils-...",
      "<hash>-curl-static-x86_64-unknown-linux-musl-8.20.0-bin",
      "<hash>-nss-cacert-3.123"
    ]
  },
  "outputs": {
    "out": { "method": "flat", "hash": "sha256-r97W5qaQ+/OtSuZa2jl/CpCl9jCzA9G3QbnJeSb91N4=" }
  },
  "version": 4
}
```

Key points, corroborated against Nix source (`derivation/json.cc` / `content-address.cc`):
- `env.out` = literal precomputed fixed path (via `nix-store --print-fixed-path`), **not** a placeholder.
- `outputs.out` = `{"method": "flat", "hash": "sha256-<SRI>"}` exactly these two keys → `CAFixed` → gets network access. `{"method","hashAlgo"}` with no `"hash"` → `CAFloating` → no network access. This is the load-bearing distinction.
- `hash` must be SRI form; `deps.json` already stores hashes in exactly this form, so no reformatting needed for real Maven hashes.
- `inputs.srcs` are basenames only (no `/nix/store/` prefix).

### 3c. Assembler inner derivation

```json
{
  "name": "deps",
  "system": "x86_64-linux",
  "builder": "/nix/store/<hash>-bash-5.3p9/bin/bash",
  "args": ["-c", "<contents of assemble.sh, a small constant-size script>"],
  "env": { "out": "<placeholder>", "manifest": "/nix/store/<hash>-manifest.tsv", "PATH": "" },
  "inputs": {
    "drvs": {
      "<drvPath-1>": { "outputs": ["out"], "dynamicOutputs": {} },
      "...": "... one entry per fetch drv (up to ~600) ..."
    },
    "srcs": ["<hash>-manifest.tsv", "<hash>-bash-5.3p9", "<hash>-coreutils-..."]
  },
  "outputs": { "out": { "method": "nar", "hashAlgo": "sha256" } },
  "version": 4
}
```

- `outputs.out` = `{"method":"nar","hashAlgo":"sha256"}` (CAFloating) — the tree's hash isn't known ahead of time, and it needs no network access anyway (pure symlinking of already-fetched things), so `env.out` correctly uses the **placeholder** here (opposite case from the fetch entries).
- `inputs.drvs` gives Nix the build-ordering dependency graph (build every fetch drv's `out` before the assembler), directly modeled on `non-trivial-submitted.nix`'s `inputDrvs` loop, just flat (≤600 independent parents) instead of a 5-node DAG.
- The manifest-file approach (rather than embedding all `ln -s` lines in `args`) is the fix for the measured `MAX_ARG_STRLEN` = 131072-byte ceiling — at ~150-250 bytes/line × 600-1097 entries, inlining would land in the 150-270KB range, well past the cap.

## 4. Scale recommendation

600 `"hash"` entries is on the edge of reasonable for a first pass, given the measured ~20-90ms/call cost of shelling out to `nix derivation add` — roughly 12-55 seconds of pure registration overhead before any network fetch starts, plus one `jq -n` and one `nix-store --print-fixed-path` call per entry. This is a **registration-time** cost only; Nix's own scheduler still parallelizes the actual ~600 independent FOD builds normally via `--max-jobs`/`--cores`.

Recommended three phases:

- **Phase 1 (minutes):** `test-small.nix`, 3-5 synthetic pairs, no deps.json. Confirms JSON shapes, SRI/hex conversion, `print-fixed-path`, manifest mechanism, `submit-output` chain end to end in isolation.
- **Phase 2 (small representative subset):** `deps-subset.json` (e.g. just `com/google/code/gson` plus a few related artifacts, ~10-30 file entries) wired into a copy of `smithy-cli/package.nix`. Confirms the resulting tree shape matches what `mitm-cache`'s proxy-replay setup hook expects, cheaply, before committing to the full artifact count.
- **Phase 3 (full scale, later):** the full 600/1097-entry `deps.json`, full `smithy-cli` build + `smithy --version`. If registration latency proves too slow in practice, the documented escape hatch (used elsewhere in nixgg for the same problem) is a persistent worker-protocol connection instead of shelling out per call — explicitly out of scope for this proof of concept.

## 5. Verification plan

### 5a. Standalone test (Phase 1)

```sh
NIX=/nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48/bin/nix
mkdir -p /tmp/dynamic-mitm-test-store

$NIX build --store 'local?root=/tmp/dynamic-mitm-test-store' \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command' \
  --extra-system-features builder-rpc-v0 \
  -f /home/tbereknyei/gradle-drvs/test-small.nix -o /tmp/dynamic-mitm-result -Lv

find /tmp/dynamic-mitm-test-store/nix/store/*-deps/https -type l -o -type f
sha256sum /tmp/dynamic-mitm-test-store/nix/store/*-deps/https/**/*
```

### 5b. Integration test (Phase 2, then Phase 3)

```sh
NIX=/nix/store/i0vbmsxgy74fj135isyhd51b15xarwwz-nix-2.36.0pre20260802_8307c48/bin/nix

# Phase 2: subset
$NIX build --store 'local?root=/tmp/smithy-subset-store' \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command configurable-impure-env' \
  --extra-system-features builder-rpc-v0 \
  -f /home/tbereknyei/gradle-drvs/smithy-cli/package.nix \
  --argstr depsFile deps-subset.json \
  -o /tmp/smithy-subset-result -Lv

# Phase 3: full deps.json, then run the binary
$NIX build --store 'local?root=/tmp/smithy-full-store' \
  --extra-experimental-features 'ca-derivations dynamic-derivations nix-command configurable-impure-env' \
  --extra-system-features builder-rpc-v0 \
  -f /home/tbereknyei/gradle-drvs/smithy-cli/package.nix \
  -o /tmp/smithy-full-result -Lv

/tmp/smithy-full-store/nix/store/*-smithy-cli-*/bin/smithy --version
/tmp/smithy-full-store/nix/store/*-smithy-cli-*/bin/smithy validate /path/to/example.smithy
```

Both the outer wrapper's own build **and** the top-level `smithy-cli` build must run under the patched Nix + local store + all relevant experimental/system-feature flags, since `mitmCache` being `builtins.outputOf outer.outPath "out"` makes the whole `smithy-cli` derivation transitively depend on the dynamic-derivation graph.

## 6. Risks / unknowns

1. **`nix derivation add` shell-out latency at ~600 calls.** Measured elsewhere at 20-90ms/call; untested at this exact scale on this machine. Mitigate by measuring during Phase 2→3; escape hatch is a persistent worker-protocol connection (out of scope here).
2. **Argv-length ceiling (`MAX_ARG_STRLEN` = 131072 bytes).** Directly hits the assembler's builder script if dest/path pairs are embedded literally in `args` — mitigated by the manifest-file design, but verify explicitly at Phase 3 scale (Phase 1/2 are too small to trigger it).
3. **`passthru.data`/`passthru.updateScript` confirmed non-load-bearing** for a basic build (verified by reading `setup-hook.sh` and `fetch-deps.nix` directly). Not replicated in the minimal version; revisit only if update-script parity becomes a goal.
4. **Disk/tmp scratch space** — no new concern versus today's `mitm-cache.fetch`; same files fetched, only the timing of derivation construction changes.
5. **Static curl choice** — recommended `pkgsStatic.curl` to minimize each per-file derivation's `inputs.srcs` list (avoids curl's dynamic-link closure per JSON blob); verified buildable on this machine.
6. **URL-to-path mapping correctness** — `mitm-cache/fetch.nix`'s `urlToPath` has scheme-specific branching and strips query strings; verify against real `deps.json` whether any non-`https` URLs appear (unlikely for Maven Central/Gradle plugin portal, but worth a quick `jq` check rather than assuming).
7. **Rate limiting** from many near-simultaneous curl fetches once Nix's scheduler parallelizes the ~600 FOD builds — no worse than today's `fetchurl`-based approach (same URLs, same total request count), but this design adds no throttling of its own.

### Critical files referenced

- `/home/tbereknyei/gradle-drvs/dynamic-mitm-cache.nix`
- `/home/tbereknyei/gradle-drvs/config.nix`
- `/home/tbereknyei/gradle-drvs/smithy-cli/package.nix`
- `/home/tbereknyei/nixpkgs/master/pkgs/by-name/mi/mitm-cache/fetch.nix`
- `/home/tbereknyei/nixpkgs/master/pkgs/development/tools/build-managers/gradle/fetch-deps.nix`
- `/home/tbereknyei/nixgg/dyn-drv/dyn-json-drv.nix`
- `/home/tbereknyei/nix/tests/functional/dyn-drv/non-trivial-submitted.nix`
