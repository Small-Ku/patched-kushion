#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"
BUILD_SOURCE_OUTPUT_DIR="$tmp/out"
BUILD_TARGET=Fixture
DL_SRCS=(direct)
declare -A args
args[direct_dlurl]="https://example.invalid/fixture.apk"

get_direct_resp() { return 0; }
dl_direct() {
  local _url=$1 _version=$2 output=$3 arch=$4
  [ "$arch" = arm64-v8a ] || return 1
  printf 'fixture-%s\n' "$arch" > "$output"
}
validate_optional_auto_abi() { return 0; }
check_sig() { return 0; }

prepare_branch_stock_sources com.example.app 1.2.3 '' '[{"arch":"arm64-v8a","optional":false},{"arch":"x86","optional":true}]'
jq -e '.shared == true and .strategy == "branches" and .availableBuildArches == ["arm64-v8a"]' "$tmp/out/source.json" >/dev/null
jq -e '.available == true and .sourceName == "direct" and .format == "APK"' "$tmp/out/branches/arm64-v8a/branch.json" >/dev/null
jq -e '.available == false and .optional == true' "$tmp/out/branches/x86/branch.json" >/dev/null

# Architecture jobs receive only their pre-acquired branch. Missing optional
# branches become a deterministic skip instead of triggering another download.
mkdir -p "$tmp/stock-source"
cp "$tmp/out/source.json" "$tmp/stock-source/source.json"
mkdir -p "$tmp/stock-source/branch"
cp -a "$tmp/out/branches/x86/." "$tmp/stock-source/branch/"
BUILD_STOCK_SOURCE_DIR="$tmp/stock-source"
rc=0
try_shared_stock_source "$tmp/stock.apk" x86 || rc=$?
[ "$rc" -eq 11 ]
[[ "$SHARED_SOURCE_UNAVAILABLE_REASON" == *x86* ]]

# A missing required branch makes the source plan incomplete; it is not handed
# downstream as a request to retry the network from an ABI job.
rm -rf "$tmp/out"
if prepare_branch_stock_sources com.example.app 1.2.3 '' '[{"arch":"arm64-v8a","optional":false},{"arch":"x86","optional":false}]'; then
  echo 'incomplete required source plan was accepted' >&2
  exit 1
fi
jq -e '.shared == false and .strategy == "branches"' "$tmp/out/source.json" >/dev/null

echo 'source stage fallback test passed'
