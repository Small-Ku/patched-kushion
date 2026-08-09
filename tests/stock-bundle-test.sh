#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
from pathlib import Path
import io, sys, zipfile
root=Path(sys.argv[1])
def apk(libs=()):
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w') as z:
        z.writestr('AndroidManifest.xml',b'manifest')
        for abi in libs: z.writestr(f'lib/{abi}/libfixture.so',b'x')
    return out.getvalue()

def bundle(path, rows):
    with zipfile.ZipFile(path,'w') as z:
        for name, libs in rows: z.writestr(name, apk(libs))

common=[
 ('base.apk',('arm64-v8a',)),
 ('split_config.arm64_v8a.apk',('arm64-v8a',)),
 ('split_config.armeabi_v7a.apk',('armeabi-v7a',)),
 ('split_config.x86.apk',('x86',)),
 ('split_config.x86_64.apk',('x86_64',)),
 ('split_config.en.apk',()),('split_config.zh.apk',()),('split_config.fr.apk',()),
 ('split_config.mdpi.apk',()),('split_config.xhdpi.apk',()),('split_config.xxhdpi.apk',()),
]
bundle(root/'fixture.apkm',common)
bundle(root/'fixture.xapk',[('com.example.app.apk',()),*common[1:]])
bundle(root/'fixture.apks',[
 ('splits/base-master.apk',()),
 ('splits/base-arm64_v8a.apk',('arm64-v8a',)),
 ('splits/base-armeabi_v7a.apk',('armeabi-v7a',)),
 ('splits/base-en.apk',()),('splits/base-xxhdpi.apk',()),
 ('standalones/standalone-arm64_v8a.apk',('arm64-v8a',)),
])
PY

for ext in apkm xapk; do
  python3 "$root/scripts/stock_bundle.py" select --bundle "$tmp/fixture.$ext" --arch universal --output-dir "$tmp/$ext-universal" > "$tmp/$ext-universal.json"
  test -f "$tmp/$ext-universal/split_config.arm64_v8a.apk"
  test -f "$tmp/$ext-universal/split_config.armeabi_v7a.apk"
  test -f "$tmp/$ext-universal/split_config.x86.apk"
  test -f "$tmp/$ext-universal/split_config.x86_64.apk"
  test -f "$tmp/$ext-universal/split_config.en.apk"
  test -f "$tmp/$ext-universal/split_config.xxhdpi.apk"

  python3 "$root/scripts/stock_bundle.py" select --bundle "$tmp/fixture.$ext" --arch arm64-v8a --output-dir "$tmp/$ext-arm64" > "$tmp/$ext-arm64.json"
  test -f "$tmp/$ext-arm64/split_config.arm64_v8a.apk"
  test ! -f "$tmp/$ext-arm64/split_config.armeabi_v7a.apk"
  test ! -f "$tmp/$ext-arm64/split_config.x86.apk"
  test -f "$tmp/$ext-arm64/split_config.en.apk"
  test -f "$tmp/$ext-arm64/split_config.zh.apk"
  test -f "$tmp/$ext-arm64/split_config.xxhdpi.apk"

  python3 "$root/scripts/stock_bundle.py" select --bundle "$tmp/fixture.$ext" --arch arm-v7a --output-dir "$tmp/$ext-armv7" > "$tmp/$ext-armv7.json"
  test -f "$tmp/$ext-armv7/base.apk" || test -f "$tmp/$ext-armv7/com.example.app.apk"
  test -f "$tmp/$ext-armv7/split_config.armeabi_v7a.apk"
  test ! -f "$tmp/$ext-armv7/split_config.arm64_v8a.apk"
  test -f "$tmp/$ext-armv7/split_config.fr.apk"
done

python3 "$root/scripts/stock_bundle.py" select --bundle "$tmp/fixture.apks" --arch arm64-v8a --output-dir "$tmp/apks-arm64" > "$tmp/apks.json"
test -f "$tmp/apks-arm64/base-master.apk"
test -f "$tmp/apks-arm64/base-arm64_v8a.apk"
test -f "$tmp/apks-arm64/base-en.apk"
test -f "$tmp/apks-arm64/base-xxhdpi.apk"
test ! -e "$tmp/apks-arm64/standalone-arm64_v8a.apk"
test ! -f "$tmp/apks-arm64/base-armeabi_v7a.apk"

python3 "$root/scripts/stock_bundle.py" inspect --bundle "$tmp/fixture.apkm" > "$tmp/inspect.json"
python3 - "$tmp/inspect.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['availableAbis'] == ['arm64-v8a','armeabi-v7a','x86','x86_64']
PY

if python3 "$root/scripts/stock_bundle.py" select --bundle "$tmp/fixture.apks" --arch x86 --output-dir "$tmp/missing" 2>"$tmp/error"; then
  echo 'missing ABI unexpectedly succeeded' >&2; exit 1
fi
grep -q 'none for x86' "$tmp/error"
echo 'stock bundle ABI selection test passed'
