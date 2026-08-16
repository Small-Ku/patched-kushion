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
args[archive_dlurl]=https://archive.org/download/example/app
args[apkmirror_dlurl]=https://www.apkmirror.com/apk/example/app/
__TOML__='{"stock-security":{"cross-source-verification":"opportunistic"}}'

for source in aptoide apkpure uptodown archive apkmirror; do
  source_needs_cross_source_verification "$source"
done
! source_needs_cross_source_verification direct

printf primary > "$tmp/primary.apk"
reset_primary() {
  printf '{"comparisonSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > "$tmp/primary.json"
}

get_uptodown_resp() { return 0; }
dl_uptodown() { printf candidate > "$3"; }
get_apkpure_resp() { return 0; }
dl_apkpure() { printf candidate > "$3"; }
validate_optional_auto_abi() { return 0; }
verify_stock_artifact_signature() { return 0; }
verify_stock_security() {
  local _apk=$1 _pkg=$2 _version=$3 source=$4 out=$5
  local family domain locator
  locator=$(configured_source_locator "$source")
  family=$(source_provenance_family "$source")
  domain=$(source_provenance_domain "$source" "$locator")
  jq -n --arg digest "$CANDIDATE_DIGEST" --arg family "$family" --arg domain "$domain" \
    '{comparisonSha256:$digest,sourceProvenanceFamily:$family,sourceProvenanceDomain:$domain}' > "$out"
}

# Store primary: a matching independent source corroborates the candidate.
DL_SRCS=(apkpure uptodown)
CANDIDATE_DIGEST=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
reset_primary
corroborate_stock_source apkpure "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="matched" and .crossSource.source=="uptodown" and .crossSource.provenanceFamily=="uptodown" and .crossSource.provenanceDomain=="uptodown.com"' "$tmp/primary.json" >/dev/null

# A real disagreement is quarantined rather than guessed away.
reset_primary
CANDIDATE_DIGEST=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
rc=0
corroborate_stock_source apkpure "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false || rc=$?
[ "$rc" -eq 20 ]
jq -e '.crossSource.status=="mismatch" and .crossSource.source=="uptodown"' "$tmp/primary.json" >/dev/null

# Network/source absence is deliberately not a hard failure; signer pin + local
# security validation remain sufficient when corroboration cannot be obtained.
reset_primary
get_uptodown_resp() { return 1; }
CANDIDATE_DIGEST=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
corroborate_stock_source apkpure "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="unavailable"' "$tmp/primary.json" >/dev/null
get_uptodown_resp() { return 0; }

# Mirrors are not exempt: APKMirror and Internet Archive primaries both trigger
# opportunistic corroboration against another independent source.
DL_SRCS=(apkpure apkmirror)
reset_primary
corroborate_stock_source apkmirror "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="matched" and .crossSource.source=="apkpure" and .crossSource.provenanceDomain=="apkpure.com"' "$tmp/primary.json" >/dev/null

DL_SRCS=(apkpure archive)
reset_primary
corroborate_stock_source archive "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="matched" and .crossSource.source=="apkpure" and .crossSource.provenanceDomain=="apkpure.com"' "$tmp/primary.json" >/dev/null

# Different downloader/source labels do not count as independent votes when they
# resolve to the same underlying provenance domain.
args[apkpure_alias_dlurl]=https://download.apkpure.com/example.apk
get_apkpure_alias_resp() { echo 'same-provenance alias should have been skipped' >&2; return 99; }
dl_apkpure_alias() { echo 'same-provenance alias should have been skipped' >&2; return 99; }
DL_SRCS=(apkpure_alias uptodown)
reset_primary
corroborate_stock_source apkpure "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="matched" and .crossSource.source=="uptodown"' "$tmp/primary.json" >/dev/null

# Explicit upstream/direct input is the only primary class that does not require
# another network source solely for quorum.
DL_SRCS=(apkpure uptodown archive apkmirror)
reset_primary
corroborate_stock_source direct "$tmp/primary.apk" "$tmp/primary.json" com.example.app 2.3.4 arm64-v8a '' false
jq -e '.crossSource.status=="not-required"' "$tmp/primary.json" >/dev/null

echo 'stock cross-source verification test passed'
