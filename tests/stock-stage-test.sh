#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"

BUILD_DIR="$tmp/build"
BUILD_TARGET=KouPhotos
BUILD_ARCH=arm64-v8a
BUILD_MODE=apk
BUILD_OPTIONAL_VARIANT=true
BUILD_STOCK_ONLY=true
BUILD_STOCK_OUTPUT_DIR="$tmp/export"
mkdir -p "$BUILD_DIR"

printf 'apk' > "$tmp/stock.apk"
printf 'bundle' > "$tmp/stock.apk.bundle"
printf '{"selected":[]}' > "$tmp/stock.apk.bundle-selection.json"
stock_sha=$(sha256sum "$tmp/stock.apk" | awk '{print toupper($1)}')
printf '{"schemaVersion":1,"artifactSha256":"%s","comparisonSha256":"%064d","securityValidated":true}\n' "$stock_sha" 1 > "$tmp/stock.apk.security.json"
CURRENT_STOCK_SOURCE=apkpure
export_stock_result "$tmp/stock.apk" com.google.android.apps.photos 7.87.0 arm64-v8a
cmp "$tmp/stock.apk" "$tmp/export/stock.apk"
test ! -e "$tmp/export/stock.bundle"
jq -e '.target=="KouPhotos" and .arch=="arm64-v8a" and .sourceName=="apkpure" and .trustClass=="third-party-store" and .sourceProvenanceFamily=="apkpure" and .sourceProvenanceDomain=="apkpure.com" and .splitContainer==true and .stockValidated==true and .securityValidated==true and (.sha256|length==64)' "$tmp/export/stock.json" >/dev/null

BUILD_STOCK_ONLY=false
BUILD_STOCK_DIR="$tmp/export"
unset BUILD_STOCK_OUTPUT_DIR
import_stock_result "$tmp/imported.apk"
cmp "$tmp/export/stock.apk" "$tmp/imported.apk"
[ "$PREPARED_STOCK_VERIFIED" = true ]
test ! -e "$tmp/imported.apk.bundle"

# Corruption across the artifact boundary is rejected before patching.
printf 'tamper' >> "$tmp/export/stock.apk"
rc=0
import_stock_result "$tmp/tampered.apk" || rc=$?
[ "$rc" -eq 2 ]
printf 'apk' > "$tmp/export/stock.apk"
cp "$tmp/stock.apk.security.json" "$tmp/export/stock.security.json"

# One stock miss is fanned out as an ordinary optional skip in every patch mode.
rm -rf "$tmp/export" "$BUILD_DIR"; mkdir -p "$tmp/export" "$BUILD_DIR"
printf '{"schemaVersion":1,"reason":"no arm64 split"}\n' > "$tmp/export/skip.json"
BUILD_STOCK_DIR="$tmp/export"
BUILD_MODE=module
rc=0
import_stock_result "$tmp/missing.apk" || rc=$?
[ "$rc" -eq 10 ]
jq -e '.reason=="no arm64 split" and .mode=="module"' "$BUILD_DIR/skip.json" >/dev/null

echo 'stock stage handoff test passed'
