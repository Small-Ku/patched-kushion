#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
BUILD_TARGET=Fixture
BUILD_PATCH_OUTPUT_DIR="$tmp/export"
printf 'patched-payload\n' > "$tmp/patched.apk"

export_patch_result "$tmp/patched.apk" com.example.app 1.2.3 arm64-v8a apk MorpheApp/morphe-patches 1.2.0 MorpheApp/morphe-patches
cmp "$tmp/patched.apk" "$tmp/export/patched.apk"
jq -e '.target=="Fixture" and .packageName=="com.example.app" and .version=="1.2.3" and .arch=="arm64-v8a" and .mode=="apk" and .patchesSource=="MorpheApp/morphe-patches" and .patchesVersion=="1.2.0" and .auxiliaryNoticeSource=="MorpheApp/morphe-patches" and (.sha256|length)==64' "$tmp/export/patch.json" >/dev/null

BUILD_PATCH_DIR="$tmp/export"
import_patch_result "$tmp/imported.apk" com.example.app 1.2.3 arm64-v8a apk MorpheApp/morphe-patches
cmp "$tmp/patched.apk" "$tmp/imported.apk"
[ "$IMPORTED_PATCHES_VERSION" = 1.2.0 ]
[ "$IMPORTED_PATCH_AUXILIARY_NOTICE_SOURCE" = MorpheApp/morphe-patches ]
! import_patch_result "$tmp/source-mismatch.apk" com.example.app 1.2.3 arm64-v8a apk other/patches >/dev/null 2>&1

# Metadata and payload are both part of the handoff contract.
! import_patch_result "$tmp/wrong.apk" com.example.app 1.2.3 arm-v7a apk MorpheApp/morphe-patches >/dev/null 2>&1
printf 'tamper\n' >> "$tmp/export/patched.apk"
! import_patch_result "$tmp/tampered.apk" com.example.app 1.2.3 arm64-v8a apk MorpheApp/morphe-patches >/dev/null 2>&1

echo 'patch stage handoff test passed'
