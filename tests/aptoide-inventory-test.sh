#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"

cat > "$tmp/aptoide.json" <<'JSON'
{
  "nodes": {
    "meta": {"data": {
      "package": "com.example.app",
      "file": {
        "vername": "3.0.0",
        "vercode": 300,
        "path": "https://cdn.example.invalid/current.apk",
        "hardware": {"cpus": ["arm64-v8a"]}
      },
      "aab": null
    }},
    "versions": {"list": [
      {
        "package": "com.example.app",
        "file": {
          "vername": "2.3.4",
          "vercode": 234,
          "path": "https://cdn.example.invalid/armv7.apk",
          "hardware": {"cpus": ["armeabi-v7a"]}
        },
        "aab": null
      },
      {
        "package": "com.example.app",
        "file": {
          "vername": "2.3.4",
          "vercode": 235,
          "path": "https://cdn.example.invalid/arm64.apk",
          "hardware": {"cpus": ["arm64-v8a"]}
        },
        "aab": null
      }
    ]}
  }
}
JSON
mapfile -t versions < <(python3 scripts/aptoide_inventory.py versions --json "$tmp/aptoide.json")
[ "${versions[*]}" = "3.0.0 2.3.4" ]
selected=$(python3 scripts/aptoide_inventory.py select --json "$tmp/aptoide.json" --version 2.3.4 --arch arm64-v8a)
[ "$(jq -r .url <<<"$selected")" = 'https://cdn.example.invalid/arm64.apk' ]
if python3 scripts/aptoide_inventory.py select --json "$tmp/aptoide.json" --version 2.3.4 --arch x86_64 >/dev/null; then
  echo 'Aptoide selector accepted a wrong-ABI historical payload' >&2
  exit 1
fi

python3 - "$tmp/arm64.apk" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('AndroidManifest.xml', b'manifest')
    z.writestr('lib/arm64-v8a/libx.so', b'x')
PY
inventory=$(cat "$tmp/aptoide.json")
req() {
  local url=$1 output=$2
  case "$url" in
    'https://ws75.aptoide.com/api/7/app/get/package_name=com.example.app/nodes=meta,versions/aab=1')
      printf '%s\n' "$inventory"
      ;;
    'https://cdn.example.invalid/arm64.apk')
      [ "$output" != - ] || return 1
      cp "$tmp/arm64.apk" "$output"
      ;;
    *) echo "unexpected request: $url" >&2; return 1 ;;
  esac
}
get_aptoide_resp com.example.app
[ "$(get_aptoide_pkg_name)" = com.example.app ]
[ "$(get_aptoide_vers | tail -1)" = 2.3.4 ]
dl_aptoide com.example.app 2.3.4 "$tmp/out.apk" arm64-v8a ''
[ "$(standalone_apk_build_arches "$tmp/out.apk")" = arm64-v8a ]
[ "$(jq -r .url "$tmp/out.apk.source.json")" = 'https://cdn.example.invalid/arm64.apk' ]

echo 'Aptoide inventory test passed'
