#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"

cat > "$tmp/history.json" <<'JSON'
{
  "version_list": [
    {
      "package_name": "com.example.app",
      "version_name": "435.0.0.37.76",
      "version_code": 10,
      "native_code": ["armeabi-v7a"],
      "asset": {"type": "XAPK", "url": "https://cdn.example.invalid/armv7.xapk"}
    },
    {
      "package_name": "com.example.app",
      "version_name": "435.0.0.37.76",
      "version_code": 11,
      "native_code": ["arm64-v8a"],
      "asset": {"type": "APK", "url": "https://cdn.example.invalid/arm64.apk"}
    },
    {
      "package_name": "com.example.app",
      "version_name": "434.0.0.0.1",
      "version_code": 9,
      "native_code": ["arm64-v8a"],
      "asset": {"type": "APK", "url": "https://cdn.example.invalid/old.apk"}
    }
  ]
}
JSON

mapfile -t versions < <(python3 scripts/apkpure_inventory.py versions --json "$tmp/history.json")
[ "${versions[*]}" = "435.0.0.37.76 434.0.0.0.1" ]
selected=$(python3 scripts/apkpure_inventory.py select --json "$tmp/history.json" --version 435.0.0.37.76 --arch arm64-v8a)
[ "$(jq -r .url <<<"$selected")" = 'https://cdn.example.invalid/arm64.apk' ]
[ "$(jq -r '.architectures | join(",")' <<<"$selected")" = arm64-v8a ]
if python3 scripts/apkpure_inventory.py select --json "$tmp/history.json" --version 435.0.0.37.76 --arch x86_64 >/dev/null; then
  echo 'APKPure selector accepted a wrong-ABI payload' >&2
  exit 1
fi

python3 - "$tmp/arm64.apk" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('AndroidManifest.xml', b'manifest')
    z.writestr('lib/arm64-v8a/libx.so', b'x')
PY
history=$(cat "$tmp/history.json")
req() {
  local url=$1 output=$2
  case "$url" in
    'https://tapi.pureapk.com/v3/get_app_his_version?package_name=com.example.app&hl=en')
      printf '%s\n' "$history"
      ;;
    'https://cdn.example.invalid/arm64.apk')
      [ "$output" != - ] || return 1
      cp "$tmp/arm64.apk" "$output"
      ;;
    *) echo "unexpected request: $url" >&2; return 1 ;;
  esac
}

unset __APKPURE_RESP__ APKEEP APKEEP_BIN || :
get_apkpure_resp com.example.app
[ "$(get_apkpure_pkg_name)" = com.example.app ]
[ "$(get_apkpure_vers | head -1)" = 435.0.0.37.76 ]
dl_apkpure com.example.app 435.0.0.37.76 "$tmp/out.apk" arm64-v8a ''
[ -s "$tmp/out.apk" ]
[ ! -e "$tmp/out.apk.bundle" ]
[ "$(jq -r .url "$tmp/out.apk.source.json")" = 'https://cdn.example.invalid/arm64.apk' ]
[ "$(standalone_apk_build_arches "$tmp/out.apk")" = arm64-v8a ]

echo 'APKPure history API test passed'
