# Resolves Gradle dependencies for a project by running its normal build
# (via gradleBuildTask, same task set the real smithy-cli recipe uses --
# guaranteed to match what's captured in deps.json) and exports the
# resulting dependency cache ($GRADLE_USER_HOME/caches/modules-2, jars-9)
# as a Nix store path.
#
# This is the thing per-module compile derivations (see
# smithy-cli-split.nix) copy into a fresh, writable $GRADLE_USER_HOME
# before running --offline. Reuses the exact mitmCache mechanism already
# proven for smithy-cli (dynamic-mitm-fetch-sharded.nix) unchanged.
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
