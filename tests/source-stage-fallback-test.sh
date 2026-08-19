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
validate_standalone_derivation() { return 0; }
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


# A plan made entirely of desired/auto branches still needs at least one actual
# payload.  An empty inventory must not become a green Source job merely because
# it has no hard-required branch.
rm -rf "$tmp/out"
if prepare_branch_stock_sources com.example.app 1.2.3 '' '[{"arch":"x86","optional":true,"sourcePriority":"desired"}]'; then
  echo 'empty desired-only source plan was accepted' >&2
  exit 1
fi
jq -e '.status == "unavailable" and .shared == false and .availableBuildArches == []' "$tmp/out/source.json" >/dev/null

# Partial broad candidates are preserved while missing auto branches continue
# through the source DAG. This is the fat-APK + split-source hybrid case.
rm -rf "$tmp/out"; mkdir -p "$tmp/out/branches/universal"
printf 'fat-universal\n' > "$tmp/out/branches/universal/stock.apk"
cat > "$tmp/out/branches/universal/branch.json" <<'JSON'
{"schemaVersion":2,"available":true,"arch":"universal","sourceName":"apkpure","format":"APK"}
JSON
cat > "$tmp/out/source.json" <<'JSON'
{"schemaVersion":2,"status":"ready","shared":true,"strategy":"branches","sourceName":"apkpure","requestedArches":[{"arch":"universal","optional":true,"sourcePriority":"desired"},{"arch":"arm64-v8a","optional":true,"sourcePriority":"desired"},{"arch":"x86","optional":true,"sourcePriority":"desired"}],"availableBuildArches":["universal"],"coverage":{"required":[],"desired":["universal","arm64-v8a","x86"],"optional":[],"available":["universal"],"missingRequired":[],"missingDesired":["arm64-v8a","x86"],"missingOptional":[]}}
JSON
prepare_branch_stock_sources com.example.app 1.2.3 '' \
  '[{"arch":"universal","optional":true,"sourcePriority":"desired"},{"arch":"arm64-v8a","optional":true,"sourcePriority":"desired"},{"arch":"x86","optional":true,"sourcePriority":"desired"}]' '' true
jq -e '.shared == true and .hybrid == true and .availableBuildArches == ["universal","arm64-v8a"] and .coverage.missingDesired == ["x86"] and (.sources | sort) == ["apkpure","direct"]' "$tmp/out/source.json" >/dev/null
grep -qx 'fat-universal' "$tmp/out/branches/universal/stock.apk"
jq -e '.sourceName == "direct" and .available == true' "$tmp/out/branches/arm64-v8a/branch.json" >/dev/null

# A provider listing blocked during acquisition (for example APKMirror returning
# 403 to a GitHub runner) is tried once per process, not once per missing ABI.
apkmirror_calls=0
get_apkmirror_resp() { apkmirror_calls=$((apkmirror_calls + 1)); return 1; }
! acquisition_source_resp apkmirror https://example.invalid/apkmirror
! acquisition_source_resp apkmirror https://example.invalid/apkmirror
[ "$apkmirror_calls" -eq 1 ]

# Branch acquisition compares all successful providers. A split-capable source
# must outrank an earlier flattened standalone so the smallest clean ABI merge is
# not hidden by provider iteration order.
rm -rf "$tmp/out"
DL_SRCS=(apkpure uptodown)
args[apkpure_dlurl]="https://example.invalid/apkpure"
args[uptodown_dlurl]="https://example.invalid/uptodown"
get_apkpure_resp() { return 0; }
get_uptodown_resp() { return 0; }
dl_apkpure() { truncate -s 10485760 "$3"; }
dl_uptodown() { : > "${3}.bundle"; }
select_bundle_splits() { mkdir -p "$3"; printf split > "$3/base.apk"; printf '{}' > "${4:-$3/selection.json}"; }
prepare_branch_stock_sources com.example.app 1.2.3 '' '[{"arch":"arm64-v8a","optional":false}]'
jq -e '.available == true and .sourceName == "uptodown" and .format == "BUNDLE"' "$tmp/out/branches/arm64-v8a/branch.json" >/dev/null

echo 'source stage fallback test passed'
