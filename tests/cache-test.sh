#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"
PATCHED_KUSHION_CACHE_DIR="$tmp/cache"

download_marker="$tmp/downloaded"
gh_dl() {
  : > "$download_marker"
  printf 'verified-apkeditor\n' > "$1"
}

# A restored APKEditor entry is executable input, so it must be revalidated;
# once its release digest matches, a cache hit must not re-download it.
apkeditor_name="APKEditor-${APKEDITOR_VERSION}.jar"
apkeditor_file="$PATCHED_KUSHION_CACHE_DIR/tools/apkeditor/${APKEDITOR_VERSION}/${apkeditor_name}"
mkdir -p "$(dirname "$apkeditor_file")"
printf 'verified-apkeditor\n' > "$apkeditor_file"
apkeditor_sha=$(sha256sum "$apkeditor_file" | awk '{print $1}')
gh_req() {
  cat <<JSON
{"assets":[{"name":"$apkeditor_name","url":"https://api.github.invalid/apkeditor","digest":"sha256:$apkeditor_sha"}]}
JSON
}
resolved=$(ensure_apkeditor)
[ "$resolved" = "$apkeditor_file" ]
[ ! -e "$download_marker" ]

# A bad restored executable is removed, downloaded once, and checked again.
printf 'tampered\n' > "$apkeditor_file"
resolved=$(ensure_apkeditor)
[ "$resolved" = "$apkeditor_file" ]
[ -e "$download_marker" ]
printf 'verified-apkeditor\n' | cmp -s - "$apkeditor_file"
rm -f "$download_marker"

# apkeep uses the same invariant and additionally requires an upstream digest.
APKEEP_VERSION=test-version
APKEEP_REPOSITORY=example/apkeep
asset=apkeep-x86_64-unknown-linux-gnu
apkeep_file="$PATCHED_KUSHION_CACHE_DIR/tools/apkeep/${APKEEP_VERSION}/${asset}"
mkdir -p "$(dirname "$apkeep_file")"
printf '#!/bin/sh\nexit 0\n' > "$apkeep_file"
chmod +x "$apkeep_file"
apkeep_sha=$(sha256sum "$apkeep_file" | awk '{print $1}')
gh_req() {
  cat <<JSON
{"assets":[{"name":"$asset","browser_download_url":"https://example.invalid/apkeep","digest":"sha256:$apkeep_sha"}]}
JSON
}
gh_dl() { echo 'cache hit attempted an apkeep download' >&2; return 99; }
unset APKEEP APKEEP_BIN
ensure_apkeep
[ "$APKEEP" = "$apkeep_file" ]

# Patch and CLI release assets use the planner-facing asset identity and must
# likewise avoid a transfer once the exact digest-checked entry is restored.
patch_dir="$PATCHED_KUSHION_CACHE_DIR/patches/Example_patches/v1"
cli_dir="$PATCHED_KUSHION_CACHE_DIR/patches/Example_cli/v2"
mkdir -p "$patch_dir" "$cli_dir"
printf 'patches\n' > "$patch_dir/patches.mpp"
printf 'cli\n' > "$cli_dir/cli-all.jar"
patch_sha=$(sha256sum "$patch_dir/patches.mpp" | awk '{print $1}')
cli_sha=$(sha256sum "$cli_dir/cli-all.jar" | awk '{print $1}')
gh_req() {
  case "$1" in
    */Example/patches/*) printf '{"tag_name":"v1","assets":[{"name":"patches.mpp","url":"https://example.invalid/patches","digest":"sha256:%s"}]}\n' "$patch_sha" ;;
    */Example/cli/*) printf '{"tag_name":"v2","assets":[{"name":"cli-all.jar","url":"https://example.invalid/cli","digest":"sha256:%s"}]}\n' "$cli_sha" ;;
    *) return 1 ;;
  esac
}
gh_dl() { echo 'cache hit attempted a patch prebuilt download' >&2; return 99; }
prebuilts=$(get_prebuilts Example/cli v2 Example/patches v1)
[ "$prebuilts" = "$patch_dir/patches.mpp $cli_dir/cli-all.jar " ]

echo 'verified helper cache test passed'
