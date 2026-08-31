set -euo pipefail
export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

# Mirrors mitm-cache/fetch.nix's `urlToPath`: strip the scheme, everything
# after becomes the relative path under $out/https/... (or $out/<scheme>/...
# for non-https URLs, matching upstream's fallback branch).
url_to_path() {
  case "$1" in
  https://*) printf '%s\n' "https/${1#https://}" ;;
  *) printf '%s\n' "${1//:\/\//\/}" ;;
  esac
}

# assembler's own derivation name must be the outer's name with the ".drv"
# suffix stripped (Nix rejects a mismatch: "was named X, expected Y").
assemblerName="${name%.drv}"

work=$(mktemp -d)
manifest="$work/manifest.tsv"
: >"$manifest"

drvBasenames=() # for the assembler's inputs.drvs (build-ordering only)

i=0
while IFS= read -r entry; do
  i=$((i + 1))
  url=$(jq -r '.key' <<<"$entry")
  kind=$(jq -r '.value | keys[0]' <<<"$entry")
  value=$(jq -r --arg k "$kind" '.value[$k]' <<<"$entry")
  relPath=$(url_to_path "$url")

  case "$kind" in
  hash)
    # A genuine fixed-output derivation gets network access even inside a
    # network-isolated builder-rpc-v0 sandbox (validated: CAFixed grants
    # it, CAFloating does not) -- this is the one case that needs the
    # dynamic-derivation dance at all.
    hashSri="$value"
    hex=$(nix hash convert --to base16 --hash-algo sha256 "$hashSri")
    fixedPath=$(nix-store --print-fixed-path sha256 "$hex" "item-$i")
    script='curl -sSfL "$url" -o "$out"'
    json=$(jq -n \
      --arg name "item-$i" \
      --arg system "$system" \
      --arg builder "$bashBin" \
      --arg script "$script" \
      --arg out "$fixedPath" \
      --arg url "$url" \
      --arg PATH "$innerPath" \
      --arg cacert "$cacertFile" \
      --arg hash "$hashSri" \
      --argjson srcs "$srcBasenames" \
      '{
        name: $name, system: $system, builder: $builder,
        args: ["-c", $script],
        env: {out: $out, url: $url, PATH: $PATH, SSL_CERT_FILE: $cacert},
        inputs: {drvs: {}, srcs: $srcs},
        outputs: {out: {method: "flat", hash: $hash}},
        version: 4
      }')
    drvPath=$(echo "$json" | nix derivation add)
    echo "item $i (fetch) -> $drvPath ($relPath)" >&2
    drvBasenames+=("$(basename "$drvPath")")
    printf 'fetch\t%s\t%s\n' "$relPath" "$fixedPath" >>"$manifest"
    ;;
  text)
    # Pure string synthesis (e.g. maven-metadata.xml): no network needed,
    # so it doesn't need a dynamic derivation at all -- the assembler
    # writes it directly from the manifest.
    printf 'text\t%s\t%s\n' "$relPath" "$(printf '%s' "$value" | base64 -w0)" >>"$manifest"
    echo "item $i (text) -> inline ($relPath)" >&2
    ;;
  redirect)
    # mitm-cache/fetch.nix's own convention: redirect = "$out/${urlToPath val}".
    printf 'redirect\t%s\t%s\n' "$relPath" "$(url_to_path "$value")" >>"$manifest"
    echo "item $i (redirect) -> $(url_to_path "$value") ($relPath)" >&2
    ;;
  *)
    echo "unknown entry kind: $kind" >&2
    exit 1
    ;;
  esac
done < <(jq -c 'to_entries[]' "$dataFile")

# Manifest is uploaded to the store (AddToStore is allowed inside a
# builder-rpc-v0 sandbox) so the assembler's own builder script stays a
# small constant size regardless of entry count -- embedding one line per
# entry directly in `args` risks the ~128KiB argv ceiling at real scale.
manifestStorePath=$(nix store add --name "${assemblerName}-manifest.tsv" "$manifest")
manifestBasename=$(basename "$manifestStorePath")

inputDrvsJson="{}"
for b in "${drvBasenames[@]}"; do
  inputDrvsJson=$(jq -c --arg k "$b" '. + {($k): {outputs: ["out"], dynamicOutputs: {}}}' <<<"$inputDrvsJson")
done

assembleScript=$(cat <<'ASSEMBLE'
set -euo pipefail
mkdir -p "$out"
while IFS=$'\t' read -r kind relPath rest; do
  mkdir -p "$out/$(dirname "$relPath")"
  case "$kind" in
  fetch) ln -s "$rest" "$out/$relPath" ;;
  text) printf '%s' "$rest" | base64 -d >"$out/$relPath" ;;
  redirect) ln -s "$out/$rest" "$out/$relPath" ;;
  esac
done <"$manifest"
ASSEMBLE
)

# The assembler's output path isn't known ahead of time (it's a plain
# nar/sha256 CAFloating output, not a fixed one) -- use the placeholder,
# not a literal path, matching the leaf-derivation pattern in
# ~/nix/tests/functional/dyn-drv/non-trivial-submitted.nix.
outPlaceholder=$(nix eval --raw --expr 'builtins.placeholder "out"')

assemblerJson=$(jq -n \
  --arg name "$assemblerName" \
  --arg system "$system" \
  --arg builder "$bashBin" \
  --arg script "$assembleScript" \
  --arg manifest "$manifestStorePath" \
  --arg out "$outPlaceholder" \
  --arg PATH "$innerPath" \
  --argjson inputDrvs "$inputDrvsJson" \
  --argjson srcs "$(jq -c --arg m "$manifestBasename" '. + [$m]' <<<"$srcBasenames")" \
  '{
    name: $name, system: $system, builder: $builder,
    args: ["-c", $script],
    env: {out: $out, PATH: $PATH, manifest: $manifest},
    inputs: {drvs: $inputDrvs, srcs: $srcs},
    outputs: {out: {method: "nar", hashAlgo: "sha256"}},
    version: 4
  }')

assemblerDrv=$(echo "$assemblerJson" | nix derivation add)
echo "assembler -> $assemblerDrv" >&2

nix store submit-output "$assemblerDrv" out
