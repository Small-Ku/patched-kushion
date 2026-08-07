#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

# shellcheck disable=SC1091
source utils.sh

notice=$(patch_notice_file MorpheApp/morphe-patches)
test "$notice" = "$repo/NOTICE"
test -s "$notice"
test "$(patch_notice_archive_name MorpheApp/morphe-patches)" = MORPHE_NOTICE.txt
if patch_notice_file RookieEnough/De-Vanced >/dev/null 2>&1; then
  echo >&2 "De-Vanced unexpectedly inherited the Morphe notice"
  exit 1
fi

# Exercise archive placement without invoking the Android signer.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp"
printf 'payload\n' > "$tmp/payload.txt"
(
  cd "$tmp"
  zip -q unsigned.apk payload.txt
)
APK_KEYSTORE_PASSWORD=test
APK_KEY_PASSWORD=test
APK_KEY_ALIAS=test
APK_APKSIGNER_KEYSTORE="$tmp/fake.p12"
APKSIGNER="$tmp/fake-apksigner.jar"
printf 'fake\n' > "$APK_APKSIGNER_KEYSTORE"
printf 'fake\n' > "$APKSIGNER"
sign_apk() {
  cp -f "$1" "$2"
}
embed_patch_notice_in_apk "$tmp/unsigned.apk" MorpheApp/morphe-patches
unzip -p "$tmp/unsigned.apk" assets/patched-kushion/notices/MORPHE_NOTICE.txt > "$tmp/embedded-notice"
cmp NOTICE "$tmp/embedded-notice"

mkdir "$tmp/module"
copy_patch_notice_to_module MorpheApp/morphe-patches "$tmp/module"
cmp NOTICE "$tmp/module/MORPHE_NOTICE.txt"

echo "patch notice test passed"
