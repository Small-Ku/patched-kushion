#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$root"
python3 - "$tmp/stock.apk" <<'PY'
from pathlib import Path
import sys,zipfile
p=Path(sys.argv[1])
with zipfile.ZipFile(p,'w') as z:
    z.writestr('AndroidManifest.xml',b'm')
    for abi in ('arm64-v8a','armeabi-v7a','x86','x86_64'):
        z.writestr(f'lib/{abi}/libx.so',abi.encode())
PY
# shellcheck disable=SC1091
source "$root/utils.sh"
prepare_stock_apk_for_build "$tmp/stock.apk" "$tmp/universal.apk" apk universal
prepare_stock_apk_for_build "$tmp/stock.apk" "$tmp/arm64.apk" apk arm64-v8a
prepare_stock_apk_for_build "$tmp/stock.apk" "$tmp/module.apk" module universal
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  unzip -l "$tmp/universal.apk" | grep -q "lib/$abi/libx.so"
done
unzip -l "$tmp/arm64.apk" | grep -q 'lib/arm64-v8a/libx.so'
! unzip -l "$tmp/arm64.apk" | grep -q 'lib/armeabi-v7a/libx.so'
! unzip -l "$tmp/arm64.apk" | grep -q 'lib/x86/libx.so'
! unzip -l "$tmp/arm64.apk" | grep -q 'lib/x86_64/libx.so'
! unzip -l "$tmp/module.apk" | grep -q 'lib/'
echo 'stock ABI stripping and universal preservation test passed'
