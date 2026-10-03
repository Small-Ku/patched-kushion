#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/stock-cache-test.py

# Exercise the real Bash import/selection boundary with a deliberately large
# signed-input fixture. Only external signer/fingerprint/JVM tools are stubbed.
source utils.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 - "$tmp" <<'PY'
import runpy, shutil, sys
from pathlib import Path
ns = runpy.run_path('tests/stock-cache-test.py')
fixture = ns['StockCacheTest']()
fixture.setUp()
cache = ns['cache']
base = fixture.root / 'common/base.apk'
with base.open('r+b') as handle:
    handle.truncate(cache.POLICY['maxPreparedBytes'])
partition = cache.load(fixture.root / 'partition.json')
partition['splits'][0].update(size=base.stat().st_size, sha256=cache.sha256(base))
cache.write(fixture.root / 'partition.json', partition)
cache.seal_source(fixture.root, 'source-key')
shutil.copytree(fixture.root, Path(sys.argv[1]) / 'source')
for arch in ('arm64-v8a', 'universal'):
    cache.prepare(fixture.root, Path(sys.argv[1]) / arch, 'App', '1.0', arch, 'source-key')
fixture.tmp.cleanup()
PY
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"
BUILD_TARGET=App BUILD_VERSION=1.0 BUILD_SOURCE_CACHE_KEY=source-key
BUILD_PATCH_OUTPUT_DIR="$tmp/patch"
merges=0 signers=0 fingerprints=0
sign_apk() { echo 'unexpected release signing' >&2; return 99; }
check_sig() { signers=$((signers + 1)); }
merge_split_dir_unsigned() { merges=$((merges + 1)); printf merged > "$2"; }
verify_stock_security() {
  fingerprints=$((fingerprints + 1))
  printf '{"securityValidated":true,"artifactSha256":"%s","comparisonSha256":"%064d"}\n' \
    "$(sha256sum "$1" | awk '{print toupper($1)}')" 1 > "$5"
}
for BUILD_ARCH in arm64-v8a universal; do
  BUILD_STOCK_DIR="$tmp/$BUILD_ARCH"
  test ! -f "$BUILD_STOCK_DIR/stock.apk"
  import_stock_result "$tmp/$BUILD_ARCH.apk"
  test -s "$tmp/$BUILD_ARCH.apk"
  jq -e '.mergeCount == 1 and .materializedBytes == 6' "$BUILD_PATCH_OUTPUT_DIR/materialization.json" >/dev/null
  test "$PREPARED_STOCK_VERIFIED" = true
  jq -e '.crossSource.status == "not-required"' "$tmp/$BUILD_ARCH.apk.security.json" >/dev/null
done
test "$merges" = 2; test "$signers" = 7; test "$fingerprints" = 2
printf tamper >> "$BUILD_STOCK_DIR/source/common/base.apk"
if import_stock_result "$tmp/tampered.apk"; then
  echo 'tampered normalized stock reached the merger' >&2; exit 1
fi
test "$merges" = 2
echo 'late materialization and fail-closed Bash handoff test passed'
