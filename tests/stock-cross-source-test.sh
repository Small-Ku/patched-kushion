#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"

declare -A args
args[apkpure_dlurl]=com.example.app
args[uptodown_dlurl]=https://example.invalid/app
DL_SRCS=(apkpure uptodown)
__TOML__='{"stock-security":{"cross-source-verification":"opportunistic"}}'

printf primary > "$tmp/primary.apk"
printf '{"comparisonSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > "$tmp/primary.json"

get_uptodown_resp() { return 0; }
dl_uptodown() { printf candidate > "$3"; }
validate_optional_auto_abi() { return 0; }
verify_stock_artifact_signature() { return 0; }
verify_stock_security() {
  local _apk=$1 _pkg=$2 _version=$3 _source=$4 out=$5
  printf '{"comparisonSha256":"%s"}\n' "${CANDIDATE_DIGEST}" > "$out"
}

CANDIDATE_DIGEST=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
corroborate_stock_source apkpure "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="matched" and .crossSource.source=="uptodown"' "$tmp/primary.json" >/dev/null

printf '{"comparisonSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > "$tmp/primary.json"
CANDIDATE_DIGEST=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
rc=0
corroborate_stock_source apkpure "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false || rc=$?
[ "$rc" -eq 20 ]
jq -e '.crossSource.status=="mismatch" and .crossSource.source=="uptodown"' "$tmp/primary.json" >/dev/null

# Network/source absence is deliberately not a hard failure; signer pin + local
# security validation remain sufficient when corroboration cannot be obtained.
printf '{"comparisonSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > "$tmp/primary.json"
get_uptodown_resp() { return 1; }
corroborate_stock_source apkpure "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="unavailable"' "$tmp/primary.json" >/dev/null

printf '{"comparisonSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > "$tmp/primary.json"
corroborate_stock_source apkmirror "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="not-required"' "$tmp/primary.json" >/dev/null

echo 'stock cross-source verification test passed'
