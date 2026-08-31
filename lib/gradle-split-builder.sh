set -euo pipefail
export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

srcBase=$(basename "$src")
depsCacheBase=$(basename "$depsCache")

modules=$(jq -r 'keys[]' "$modulesJson")

declare -A drvBase   # module -> its own drv basename (once registered)
declare -A drvOut    # module -> input placeholder for its "out"
declare -A visited

# Nix's DownstreamPlaceholder::unknownCaOutput formula (see
# ~/nix/src/libstore/downstream-placeholder.cc) -- builtins.storePath is
# blocked inside a builder-rpc-v0 sandbox ("Operation not allowed"), so we
# reimplement the placeholder computation directly rather than relying on
# builtins.outputOf from inside the sandbox.
placeholder_for() {
  local drvPath="$1"
  local base
  base=$(basename "$drvPath")
  local hashPart="${base%%-*}"
  local drvName="${base#*-}"
  drvName="${drvName%.drv}"
  local clearText="nix-upstream-output:${hashPart}:${drvName}"
  local hex nix32
  hex=$(printf '%s' "$clearText" | sha256sum | cut -d' ' -f1)
  nix32=$(nix hash convert --from base16 --to nix32 --hash-algo sha256 "$hex")
  printf '/%s' "$nix32"
}

register_module() {
  local mod="$1"
  [ -n "${visited[$mod]:-}" ] && return
  visited[$mod]=1

  local task deps depDrvsJson script placeholderOwn jarModuleDir
  task=$(jq -r --arg m "$mod" '.[$m].task' "$modulesJson")
  jarModuleDir=$(jq -r --arg m "$mod" '.[$m].jarDir' "$modulesJson")
  mapfile -t deps < <(jq -r --arg m "$mod" '.[$m].deps[]?' "$modulesJson")

  depDrvsJson="{}"
  # Seed this module's build-cache dir from every upstream module's
  # already-built cache output before running gradle -- this is what
  # makes cross-module compilation results (FROM-CACHE) flow forward.
  seedCacheScript=""
  for dep in "${deps[@]}"; do
    register_module "$dep"
    depDrvsJson=$(jq -c --arg k "${drvBase[$dep]}" '. + {($k): {outputs: ["out"], dynamicOutputs: {}}}' <<<"$depDrvsJson")
    seedCacheScript+="cp -rn \"${drvOut[$dep]}/cache\"/* \"\$buildCacheDir\"/ 2>/dev/null || true
"
  done

  placeholderOwn=$(nix eval --raw --expr 'builtins.placeholder "out"')

  script=$(cat <<SCRIPT
set -euo pipefail
export HOME="\$TMPDIR/home"
mkdir -p "\$HOME"
export GRADLE_USER_HOME="\$TMPDIR/gradle-home"
mkdir -p "\$GRADLE_USER_HOME/caches"
cp -r "$depsCache/caches/"* "\$GRADLE_USER_HOME/caches/" 2>/dev/null || true
chmod -R u+w "\$GRADLE_USER_HOME/caches"
buildCacheDir="\$TMPDIR/build-cache"
mkdir -p "\$buildCacheDir"
$seedCacheScript
chmod -R u+w "\$buildCacheDir"
srcDir="\$TMPDIR/src"
cp -r "$src" "\$srcDir"
chmod -R u+w "\$srcDir"
cat > "\$srcDir/init-cache.gradle" <<'INITEOF'
settingsEvaluated { settings ->
    settings.buildCache {
        local {
            directory = System.getenv("NIX_BUILD_CACHE_DIR")
            removeUnusedEntriesAfterDays = 30
        }
    }
}
INITEOF
export NIX_BUILD_CACHE_DIR="\$buildCacheDir"
gradle -p "\$srcDir" --init-script "\$srcDir/init-cache.gradle" $task --build-cache --offline --no-daemon
mkdir -p "\$out/cache" "\$out/jars"
cp -r "\$buildCacheDir"/* "\$out/cache"/ 2>/dev/null || true
find "\$srcDir/$jarModuleDir/build/libs" -iname '*.jar' -exec cp {} "\$out/jars"/ \; 2>/dev/null || true
SCRIPT
)

  json=$(jq -n \
    --arg name "$mod" \
    --arg system "$system" \
    --arg builder "$bashBin" \
    --arg script "$script" \
    --arg out "$placeholderOwn" \
    --arg PATH "$innerPath" \
    --argjson drvs "$depDrvsJson" \
    --argjson srcs "$(jq -c --arg s "$srcBase" --arg d "$depsCacheBase" '. + [$s, $d]' <<<"$srcBasenames")" \
    '{
      name: $name, system: $system, builder: $builder,
      args: ["-c", $script],
      env: {out: $out, PATH: $PATH},
      inputs: {drvs: $drvs, srcs: $srcs},
      outputs: {out: {method: "nar", hashAlgo: "sha256"}},
      version: 4
    }')

  drvPath=$(echo "$json" | nix derivation add)
  echo "module $mod -> $drvPath (deps: ${deps[*]:-none})" >&2
  drvBase[$mod]="$(basename "$drvPath")"
  drvOut[$mod]=$(placeholder_for "$drvPath")
}

for mod in $modules; do
  register_module "$mod"
done

# assembler's own derivation name must be the outer's name with the ".drv"
# suffix stripped (Nix rejects a mismatch). It collects every visited
# module's compiled jars into one flat $out -- not just the final module's
# -- mirroring how a real multi-module Gradle build's installPhase copies
# jars from every module it built (see smithy-cli/package.nix).
assemblerName="${name%.drv}"
assemblerPlaceholderOwn=$(nix eval --raw --expr 'builtins.placeholder "out"')

assembleScript="mkdir -p \$out"
assemblerInputDrvs="{}"
for mod in "${!drvOut[@]}"; do
  assembleScript+="
cp \"${drvOut[$mod]}/jars\"/*.jar \$out/ 2>/dev/null || true"
  assemblerInputDrvs=$(jq -c --arg k "${drvBase[$mod]}" '. + {($k): {outputs: ["out"], dynamicOutputs: {}}}' <<<"$assemblerInputDrvs")
done

assemblerJson=$(jq -n \
  --arg name "$assemblerName" \
  --arg system "$system" \
  --arg builder "$bashBin" \
  --arg script "$assembleScript" \
  --arg out "$assemblerPlaceholderOwn" \
  --arg PATH "$innerPath" \
  --argjson drvs "$assemblerInputDrvs" \
  --argjson srcs "$(jq -c --arg s "$srcBase" --arg d "$depsCacheBase" '. + [$s, $d]' <<<"$srcBasenames")" \
  '{
    name: $name, system: $system, builder: $builder,
    args: ["-c", $script],
    env: {out: $out, PATH: $PATH},
    inputs: {drvs: $drvs, srcs: $srcs},
    outputs: {out: {method: "nar", hashAlgo: "sha256"}},
    version: 4
  }')

assemblerDrv=$(echo "$assemblerJson" | nix derivation add)
echo "assembler -> $assemblerDrv" >&2

nix store submit-output "$assemblerDrv" out
