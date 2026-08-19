#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$root"
python3 - "$tmp/noarch.apk" "$tmp/multi.apk" <<'PY'
from pathlib import Path
import sys,zipfile
for path,abis in [(Path(sys.argv[1]),()),(Path(sys.argv[2]),('arm64-v8a','armeabi-v7a'))]:
    with zipfile.ZipFile(path,'w') as z:
        z.writestr('AndroidManifest.xml',b'm')
        for abi in abis:z.writestr(f'lib/{abi}/libx.so',b'x')
PY
# shellcheck disable=SC1091
source "$root/utils.sh"
BUILD_OPTIONAL_VARIANT=true
BUILD_TARGET=Fixture BUILD_MODE=apk BUILD_DIR="$tmp/build"; mkdir -p "$BUILD_DIR"
BUILD_ARCH=arm64-v8a
if validate_optional_auto_abi "$tmp/noarch.apk" arm64-v8a; then
  echo 'noarch APK unexpectedly produced an ABI-specific auto variant' >&2; exit 1
fi
grep -q 'ABI-independent' "$BUILD_DIR/skip.json"
rm -f "$BUILD_DIR/skip.json"
if validate_optional_auto_abi "$tmp/multi.apk" arm64-v8a; then
  echo 'fat standalone APK unexpectedly produced an ABI-specific auto variant' >&2; exit 1
fi
grep -q 'multi-ABI' "$BUILD_DIR/skip.json"
rm -f "$BUILD_DIR/skip.json"
BUILD_ARCH=x86
if validate_optional_auto_abi "$tmp/multi.apk" x86; then
  echo 'missing x86 native payload unexpectedly accepted' >&2; exit 1
fi
grep -q 'multi-ABI' "$BUILD_DIR/skip.json"
validate_optional_auto_abi "$tmp/noarch.apk" universal
echo 'auto ABI meaningfulness test passed'
