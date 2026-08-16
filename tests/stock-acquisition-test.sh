#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$root"

python3 - "$tmp/source.apkm" <<'PY'
from pathlib import Path
import io,sys,zipfile
path=Path(sys.argv[1])
def apk(libs=()):
    b=io.BytesIO()
    with zipfile.ZipFile(b,'w') as z:
        z.writestr('AndroidManifest.xml',b'm')
        for abi in libs: z.writestr(f'lib/{abi}/libx.so',b'x')
    return b.getvalue()
with zipfile.ZipFile(path,'w') as z:
    z.writestr('base.apk',apk())
    z.writestr('split_config.arm64_v8a.apk',apk(('arm64-v8a',)))
    z.writestr('split_config.armeabi_v7a.apk',apk(('armeabi-v7a',)))
    z.writestr('split_config.en.apk',apk())
    z.writestr('split_config.zh.apk',apk())
    z.writestr('split_config.xxhdpi.apk',apk())
PY

# shellcheck disable=SC1091
source "$root/utils.sh"
# shellcheck disable=SC1091
source "$root/tests/testlib.sh"
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"
FIXTURE="$tmp/source.apkm"
CAPTURE="$tmp/capture.txt"

req() { cp "$FIXTURE" "$2"; }
gh_dl() { : > "$1"; }
sign_apk() { cp "$1" "$2"; }
java() {
  local input='' output='' prev=''
  for arg in "$@"; do
    if [ "$prev" = -i ]; then input=$arg; fi
    if [ "$prev" = -o ]; then output=$arg; fi
    prev=$arg
  done
  find "$input" -maxdepth 1 -type f -name '*.apk' -printf '%f\n' | sort > "$CAPTURE"
  printf 'merged' > "$output"
}

__ARCHIVE_RESP__='com.example.app-1.0-all.apkm'
dl_archive 'https://example.invalid/app' '1.0' "$tmp/archive-universal.apk" 'universal'
test -f "$tmp/archive-universal.apk"
grep -qx 'split_config.arm64_v8a.apk' "$CAPTURE"
grep -qx 'split_config.armeabi_v7a.apk' "$CAPTURE"
grep -qx 'split_config.en.apk' "$CAPTURE"

dl_archive 'https://example.invalid/app' '1.0' "$tmp/archive-arm64.apk" 'arm64-v8a'
test -f "$tmp/archive-arm64.apk"
grep -qx 'split_config.arm64_v8a.apk' "$CAPTURE"
! grep -q 'armeabi_v7a' "$CAPTURE"
grep -qx 'split_config.en.apk' "$CAPTURE"
grep -qx 'split_config.zh.apk' "$CAPTURE"
grep -qx 'split_config.xxhdpi.apk' "$CAPTURE"

rm -f "$tmp/archive-arm64.apk" "$tmp/archive-arm64.apk.bundle"
dl_archive 'https://example.invalid/app' '1.0' "$tmp/archive-armv7.apk" 'arm-v7a'
test -f "$tmp/archive-armv7.apk"
grep -qx 'split_config.armeabi_v7a.apk' "$CAPTURE"
! grep -q 'arm64_v8a' "$CAPTURE"
grep -qx 'split_config.en.apk' "$CAPTURE"

version_f=1.0
dl_direct 'https://example.invalid/com.example.app-1.0-all.xapk' '1.0' "$tmp/direct-arm64.apk" 'arm64-v8a' ''
test -f "$tmp/direct-arm64.apk"
grep -qx 'split_config.arm64_v8a.apk' "$CAPTURE"
! grep -q 'armeabi_v7a' "$CAPTURE"


# A failed source must not leave a canonical bundle that poisons the next source.
python3 - "$tmp/arm64-only.apkm" <<'PY_FAIL_BUNDLE'
from pathlib import Path
import io,sys,zipfile
path=Path(sys.argv[1])
def apk(libs=()):
    b=io.BytesIO()
    with zipfile.ZipFile(b,'w') as z:
        z.writestr('AndroidManifest.xml',b'm')
        for abi in libs: z.writestr(f'lib/{abi}/libx.so',b'x')
    return b.getvalue()
with zipfile.ZipFile(path,'w') as z:
    z.writestr('base.apk',apk())
    z.writestr('split_config.arm64_v8a.apk',apk(('arm64-v8a',)))
    z.writestr('split_config.en.apk',apk())
PY_FAIL_BUNDLE
OLD_FIXTURE=$FIXTURE
FIXTURE="$tmp/arm64-only.apkm"
expect_failure_matching \
  'reject a split container without the requested ABI' 1 \
  "Could not select a coherent split set for 'arm-v7a'" \
  download_split_container 'https://example.invalid/bad.apkm' "$tmp/fallback.apk" 'arm-v7a'
test ! -e "$tmp/fallback.apk.bundle"
test ! -e "$tmp/fallback.apk.candidate.bundle"
FIXTURE=$OLD_FIXTURE
download_split_container 'https://example.invalid/good.apkm' "$tmp/fallback.apk" 'arm-v7a'
test -f "$tmp/fallback.apk.bundle"
grep -qx 'split_config.armeabi_v7a.apk' "$CAPTURE"

echo 'stock acquisition ABI-selective merge test passed'
