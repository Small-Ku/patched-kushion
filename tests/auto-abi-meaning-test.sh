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

expect_optional_unavailable() {
  local apk=$1 arch=$2 pattern=$3 log
  log="$tmp/optional-${arch}.log"
  BUILD_ARCH=$arch
  if GITHUB_REPOSITORY=Small-Ku/patched-kushion validate_optional_auto_abi "$apk" "$arch" 2>"$log"; then
    echo "optional $arch variant unexpectedly succeeded" >&2
    exit 1
  fi
  grep -q "$pattern" "$BUILD_DIR/skip.json"
  grep -Fq '::notice::utils.sh [i] Optional variant unavailable:' "$log"
  if grep -Eq '^::(error|warning)::' "$log"; then
    echo "optional $arch discovery emitted an error/warning annotation" >&2
    cat "$log" >&2
    exit 1
  fi
  rm -f "$BUILD_DIR/skip.json"
}

expect_optional_unavailable "$tmp/noarch.apk" arm64-v8a 'ABI-independent'
expect_optional_unavailable "$tmp/multi.apk" arm64-v8a 'multi-ABI'
expect_optional_unavailable "$tmp/multi.apk" x86 'multi-ABI'
BUILD_ARCH=universal
validate_optional_auto_abi "$tmp/noarch.apk" universal
echo 'auto ABI meaningfulness test passed'
