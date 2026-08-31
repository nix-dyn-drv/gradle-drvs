# Resolves Gradle dependencies for a project (via gradleBuildTask, the same
# task set the real recipe uses, so it matches deps.json) and exports just
# the resulting dependency cache. gradle-split.nix's per-module derivations
# copy this into a fresh, writable $GRADLE_USER_HOME before running
# --offline.
{
  lib,
  stdenvNoCC,
  gradle,
  src,
  mitmCache,
  gradleBuildTask,
  name ? "gradle-deps-cache",
}:

stdenvNoCC.mkDerivation {
  inherit
    name
    src
    mitmCache
    gradleBuildTask
    ;

  strictDeps = true;

  nativeBuildInputs = [ gradle ];

  __darwinAllowLocalNetworking = true;

  dontUseGradleCheck = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/caches
    for d in modules-2 jars-9; do
      if [ -d "$GRADLE_USER_HOME/caches/$d" ]; then
        cp -r "$GRADLE_USER_HOME/caches/$d" "$out/caches/$d"
      fi
    done
    runHook postInstall
  '';
}
