#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"

cat > "$tmp/versions.html" <<'HTML'
<html><body><div class="version_history">
  <div class="list">
    <div class="package_info open_info"><div class="title">Instagram <span class="version">435.0.0.37.76</span></div></div>
    <div class="variant">Instagram 435.0.0.37.76 (384109456)
      <div>Requires Android: Android 9.0+</div><div>Architecture: arm64-v8a</div><div>Screen DPI: nodpi</div>
      <div>SHA1: 2b99ac1be79e586d93832213c24598c30f5f7801</div><div>Base APK: com.instagram.android.apk</div>
      <div>Split APKs: config.mdpi</div><div>Size: 128.34 MB</div>
    </div>
    <div class="variant">Instagram 435.0.0.37.76 (384109456)
      <div>Requires Android: Android 9.0+</div><div>Architecture: arm64-v8a</div><div>Screen DPI: nodpi</div>
      <div>SHA1: 6a39b0475b9f8c4e1aafe0ac837f0325a031af9a</div><div>Base APK: com.instagram.android.apk</div>
      <div>Split APKs: config.xxxhdpi</div><div>Size: 132.69 MB</div>
    </div>
    <div class="variant">Instagram 435.0.0.37.76 (384209396)
      <div>Requires Android: Android 8.0+</div><div>Architecture: armeabi-v7a</div><div>Screen DPI: nodpi</div>
      <div>SHA1: d7476e8e8233984a72e2135054ed2e37d2d98cfb</div><div>Base APK: com.instagram.android.apk</div>
      <div>Split APKs: config.xhdpi</div><div>Size: 132.21 MB</div>
    </div>
  </div>
  <div class="list"><div class="package_info open_info"><div class="title">Instagram <span class="version">434.0.0.44.74</span></div></div></div>
</div></body></html>
HTML

cat > "$tmp/download.html" <<'HTML'
<html><body>
<a href="/instagram/com.instagram.android/download?sha1=2b99ac1be79e586d93832213c24598c30f5f7801">Restart</a>
<script>
window.analyticsDownload = "https:\/\/download.apkfab.example\/help";
window.__download = "https:\/\/download.apkfab.example\/prepare?token=abc";
</script>
</body></html>
HTML

cat > "$tmp/help.html" <<'HTML'
<html><body>download help only</body></html>
HTML

cat > "$tmp/prepare.html" <<'HTML'
<html><body data-download-url="https://cdn.apkfab.example/payload/instagram-435-arm64.xapk?token=final">Preparing download</body></html>
HTML

python3 - "$tmp/payload.xapk" <<'PYZIP'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("base.apk", b"not-a-real-apk-but-a-zip-fixture")
PYZIP

mapfile -t versions < <(python3 scripts/apkfab_inventory.py versions --html "$tmp/versions.html")
[ "${versions[0]}" = 435.0.0.37.76 ]
[ "${versions[1]}" = 434.0.0.44.74 ]

selected=$(python3 scripts/apkfab_inventory.py select --html "$tmp/versions.html" \
  --version 435.0.0.37.76 --arch arm64-v8a --base-url https://apkfab.com/instagram/com.instagram.android)
jq -e '
  .version == "435.0.0.37.76" and
  .versionCode == 384109456 and
  .architectures == ["arm64-v8a"] and
  .sha1 == "2b99ac1be79e586d93832213c24598c30f5f7801" and
  .format == "XAPK" and
  (.downloadPage | endswith("/download?sha1=2b99ac1be79e586d93832213c24598c30f5f7801"))
' >/dev/null <<<"$selected"

armv7=$(python3 scripts/apkfab_inventory.py select --html "$tmp/versions.html" \
  --version 435.0.0.37.76 --arch arm-v7a --base-url https://apkfab.com/instagram/com.instagram.android)
jq -e '.versionCode == 384209396 and .architectures == ["armeabi-v7a"]' >/dev/null <<<"$armv7"

mapfile -t resolved < <(python3 scripts/apkfab_inventory.py resolve-all --html "$tmp/download.html" \
  --page-url 'https://apkfab.com/instagram/com.instagram.android/download?sha1=2b99ac1be79e586d93832213c24598c30f5f7801')
printf '%s\n' "${resolved[@]}" | grep -Fxq 'https://download.apkfab.example/help'
printf '%s\n' "${resolved[@]}" | grep -Fxq 'https://download.apkfab.example/prepare?token=abc'

req() {
  local url=$1 output=$2
  shift 2
  case "$url" in
    https://apkfab.com/instagram/com.instagram.android/versions)
      [ "$output" = - ] || return 1
      cat "$tmp/versions.html"
      ;;
    https://apkfab.com/instagram/com.instagram.android/download\?sha1=2b99ac1be79e586d93832213c24598c30f5f7801)
      [ "$output" != - ] || return 1
      cp "$tmp/download.html" "$output"
      ;;
    https://download.apkfab.example/help)
      cp "$tmp/help.html" "$output"
      ;;
    https://download.apkfab.example/prepare\?token=abc)
      cp "$tmp/prepare.html" "$output"
      ;;
    https://cdn.apkfab.example/payload/instagram-435-arm64.xapk\?token=final)
      cp "$tmp/payload.xapk" "$output"
      ;;
    *) echo "unexpected APKFab request: $url" >&2; return 1 ;;
  esac
}

merge_splits() {
  is_zip_payload "$1"
  [ "$3" = arm64-v8a ]
  printf 'merged-apk\n' > "$2"
}

get_apkfab_resp https://apkfab.com/instagram/com.instagram.android
[ "$(get_apkfab_pkg_name)" = com.instagram.android ]
[ "$(get_apkfab_vers | head -1)" = 435.0.0.37.76 ]
dl_apkfab https://apkfab.com/instagram/com.instagram.android 435.0.0.37.76 "$tmp/instagram.apk" arm64-v8a ''
[ -s "$tmp/instagram.apk" ]
jq -e '.source == "apkfab" and .version == "435.0.0.37.76" and .arch == "arm64-v8a" and .sha1 == "2b99ac1be79e586d93832213c24598c30f5f7801" and .format == "XAPK" and .url == "https://cdn.apkfab.example/payload/instagram-435-arm64.xapk?token=final"' \
  "${tmp}/instagram.apk.source.json" >/dev/null

[ "$(source_trust_class apkfab)" = third-party-store ]
[ "$(source_provenance_family apkfab)" = apkfab ]
[ "$(source_provenance_domain apkfab https://apkfab.com/instagram/com.instagram.android)" = apkfab.com ]

echo '[PASS] APKFab exact-version source follows interstitial hops and accepts only a valid ZIP payload'
