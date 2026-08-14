#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"

python3 - "$tmp/source.apkm" <<'PY'
import io,sys,zipfile

def apk(libs=()):
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w') as z:
        z.writestr('AndroidManifest.xml',b'manifest')
        for abi in libs: z.writestr(f'lib/{abi}/libx.so',b'x')
    return out.getvalue()
with zipfile.ZipFile(sys.argv[1],'w') as z:
    z.writestr('base.apk',apk())
    z.writestr('split_config.arm64_v8a.apk',apk(('arm64-v8a',)))
    z.writestr('split_config.armeabi_v7a.apk',apk(('armeabi-v7a',)))
    z.writestr('split_config.en.apk',apk())
    z.writestr('split_config.xxhdpi.apk',apk())
PY

declare -A args
args[direct_dlurl]="https://example.invalid/source.apkm"
SHARED_DL_SRCS=(direct)
BUILD_SOURCE_OUTPUT_DIR="$tmp/out"
BUILD_TARGET=Fixture
check_sig() { return 0; }
get_direct_resp() { return 0; }
req() {
  local _url=$1 out=$2
  [ "$out" != - ] || return 1
  cp "$tmp/source.apkm" "$out"
}

prepare_shared_stock_source com.example 1.0 '' '[{"arch":"arm64-v8a"},{"arch":"arm-v7a"}]'
jq -e '.shared == true and .availableBuildArches == ["arm64-v8a","arm-v7a"]' "$tmp/out/source.json" >/dev/null
test -f "$tmp/out/common/base.apk"
test -f "$tmp/out/common/split_config.en.apk"
test -f "$tmp/out/abi/arm64-v8a/split_config.arm64_v8a.apk"
test -f "$tmp/out/abi/arm-v7a/split_config.armeabi_v7a.apk"
test -f "$tmp/out/abi/x86/availability.json"

echo 'shared source stage test passed'
