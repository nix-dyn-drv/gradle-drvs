{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  gradle,
  jre,
  makeWrapper,
  runCommand,
  versionCheckHook,
  writeText,
  pkgs,
  patchedNix,
}:

let
  dynamicMitmFetch = import ../dynamic-mitm-fetch.nix { inherit pkgs patchedNix; };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "smithy-cli";
  version = "1.72.1";

  src = fetchFromGitHub {
    owner = "smithy-lang";
    repo = "smithy";
    tag = finalAttrs.version;
    hash = "sha256-IBqh2ATKi5MfaCjvXz7KE2p3lGJa8Sn3YhOuwaW1/sk=";
  };

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [
    gradle
    makeWrapper
  ];

  __darwinAllowLocalNetworking = true;

  # Only change from upstream package.nix: mitmCache is produced by a
  # builder-rpc-v0 dynamic derivation (dynamic-mitm-fetch.nix) instead of
  # gradle.fetchDeps -> mitm-cache.fetch's eager, eval-time fetchurl/writeText
  # construction. Still reuses gradle.fetchDeps's own JSON decompression /
  # maven-metadata.xml synthesis unchanged (only its final fetch step is
  # replaced) -- see ../test-smithy-mitm.nix and ../README.md.
  mitmCache =
    let
      expanded = gradle.fetchDeps {
        pkg = { pname = finalAttrs.pname; };
        data = ./deps.json;
      };
      expandedData = builtins.fromJSON (builtins.readFile expanded.data);
    in
    (dynamicMitmFetch {
      name = "${finalAttrs.pname}-deps";
      data = builtins.removeAttrs expandedData [ "!version" ];
    }).result;

  gradleBuildTask = ":smithy-cli:shadowJar";
  gradleUpdateTask = ":smithy-cli:shadowJar :smithy-cli:test";

  doCheck = true;
  gradleCheckTask = ":smithy-cli:test";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,share/smithy-cli/lib}

    for proj in smithy-cli smithy-utils smithy-model smithy-build smithy-diff smithy-syntax; do
      cp $proj/build/libs/$proj-${finalAttrs.version}.jar $out/share/smithy-cli/lib/
    done

    makeWrapper ${lib.getExe jre} $out/bin/smithy \
      --set CLASSPATH "$out/share/smithy-cli/lib/*" \
      --add-flags "software.amazon.smithy.cli.SmithyCli"

    runHook postInstall
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  passthru = {
    tests.validate = runCommand "smithy-cli-validate-test" { } ''
      ${lib.getExe finalAttrs.finalPackage} validate ${writeText "example.smithy" ''
        $version: "2.0"
        namespace example
        service ExampleService {
            version: "2023-01-01"
            operations: [GetUser]
        }
        operation GetUser {
            input: GetUserInput
            output: GetUserOutput
        }
        structure GetUserInput {
            @required
            userId: String
        }
        structure GetUserOutput {
            @required
            name: String
        }
      ''}
      touch $out
    '';
  };

  meta = {
    description = "CLI for the Smithy interface definition language (IDL)";
    homepage = "https://smithy.io/";
    license = lib.licenses.asl20;
    mainProgram = "smithy";
    inherit (jre.meta) platforms;
  };
})
