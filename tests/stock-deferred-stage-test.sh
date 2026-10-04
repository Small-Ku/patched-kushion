#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
source "$root/tests/testlib.sh"

# Run the actual build entry point in an isolated fixture repository. External
# JVM/signature/fingerprint tools are replaced below; preparation, completion,
# source selection, identity checks and late import use the repository code.
mkdir -p "$tmp/repo"
cp "$root/build.sh" "$root/utils.sh" "$tmp/repo/"
ln -s "$root/scripts" "$tmp/repo/scripts"
ln -s "$root/bin" "$tmp/repo/bin"
cat > "$tmp/repo/config.toml" <<'TOML'
config-version = 1
[build]
enable-module-update = false
[apps.App]
display-name = "App"
upstream-package = "com.example"
package-name = "de.kwoo.shion.app"
[apps.App.build]
version = "1.0"
build-mode = "apk"
TOML
cat >> "$tmp/repo/utils.sh" <<'SH'
java() { return 0; }
check_sig() {
  [ "${REJECT_SIGNER:-false}" != true ] || return 2
  printf '%s\n' "$1" >> "$TEST_SIGNERS"
}
merge_split_dir_unsigned() {
  [ "${BUILD_STOCK_ONLY:-false}" != true ] || { echo 'early merge' >&2; return 99; }
  printf 'merge\n' >> "$TEST_MERGES"
  python3 - "$1" "$2" <<'PY'
import sys, zipfile
from pathlib import Path
with zipfile.ZipFile(sys.argv[2], 'w', compression=zipfile.ZIP_STORED) as output:
    for apk in sorted(Path(sys.argv[1]).glob('*.apk')):
        with zipfile.ZipFile(apk) as source:
            for name in source.namelist():
                output.writestr(name, source.read(name))
PY
}
verify_stock_security() {
  [ "${REJECT_SECURITY:-false}" != true ] || return 2
  printf '{"securityValidated":true,"artifactSha256":"%s","comparisonSha256":"%064d"}\n' \
    "$(sha256sum "$1" | awk '{print toupper($1)}')" 1 > "$5"
}
SH
python3 - "$root" "$tmp" <<'PY'
import runpy, shutil, sys, zipfile
from pathlib import Path
ns = runpy.run_path(str(Path(sys.argv[1]) / 'tests/stock-cache-test.py'))
fixture = ns['StockCacheTest']()
fixture.setUp()
cache = ns['cache']
dest = Path(sys.argv[2])
partition = cache.load(fixture.root / 'partition.json')
for row in partition['splits']:
    name = ('common/' if row['bucket'] == 'common' else f"abi/{row['bucket']}/") + row['output']
    path = fixture.root / name
    # Real readable ZIP payloads; selected APK bytes exceed 100 MiB while each
    # individual source split stays below that size. Do not lower the policy cap.
    size = 60 * 1024 * 1024 if row['output'] == 'base.apk' else 45 * 1024 * 1024 if row['output'] == 'config.en.apk' else 1024
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as apk:
        apk.writestr(f"assets/{row['output']}.bin", bytes(size))
    row.update(size=path.stat().st_size, sha256=cache.sha256(path))
cache.write(fixture.root / 'partition.json', partition)
cache.seal_source(fixture.root, 'source-key')
shutil.copytree(fixture.root, dest / 'partition')
branch_root = dest / 'branches'
meta = {**fixture.meta, 'strategy': 'branches'}
cache.write(branch_root / 'source.json', meta)
for arch in meta['availableBuildArches']:
    branch = branch_root / 'branches' / arch
    cache.write(branch / 'branch.json', {'arch': arch, 'available': True,
                'signerVerified': True, 'sourceName': 'direct', 'verification': fixture.summary})
    cache.write(branch / 'source.security.json', fixture.security)
    for row in partition['splits']:
        if row['bucket'] != 'common' and arch != 'universal' and row['bucket'] != arch:
            continue
        prefix = 'common' if row['bucket'] == 'common' else f"abi/{row['bucket']}"
        target = branch / 'splits' / row['output']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(fixture.root / prefix / row['output'], target)
cache.seal_source(branch_root, 'source-key')
fixture.tmp.cleanup()
PY
cd "$tmp/repo"
export BUILD_TARGET=App BUILD_VERSION=1.0 BUILD_MODE=apk BUILD_STOCK_OFFLINE=true
export BUILD_SOURCE_CACHE_KEY=source-key BUILD_STOCK_CACHE_V3=true BUILD_STOCK_ONLY=true
export TEST_MERGES="$tmp/merges" TEST_SIGNERS="$tmp/signers"
for strategy in partition branches; do
  for BUILD_ARCH in arm64-v8a arm-v7a universal; do
    export BUILD_ARCH
    if [ "$strategy" = branches ]; then
      BUILD_STOCK_SOURCE_DIR="$tmp/selected"
      rm -rf "$BUILD_STOCK_SOURCE_DIR"
      mkdir -p "$BUILD_STOCK_SOURCE_DIR"
      cp "$tmp/branches/source.json" "$tmp/branches/source.cache.json" "$BUILD_STOCK_SOURCE_DIR/"
      cp -r "$tmp/branches/branches/$BUILD_ARCH" "$BUILD_STOCK_SOURCE_DIR/branch"
    else
      BUILD_STOCK_SOURCE_DIR="$tmp/partition"
    fi
    export BUILD_STOCK_SOURCE_DIR BUILD_STOCK_OUTPUT_DIR="$tmp/stock-$strategy-$BUILD_ARCH"
    bash build.sh > "$tmp/stock.log" 2>&1 || { cat "$tmp/stock.log"; exit 1; }
    grep -q 'Prepared stock input' "$tmp/stock.log"
    test ! -e "$BUILD_STOCK_OUTPUT_DIR/stock.apk"
    test ! -e "$TEST_MERGES"
    test ! -e "$TEST_SIGNERS"
    jq -e '.mergeDeferred == true and .mergeCount == 0 and .selectedSourceBytes > 104857600' "$BUILD_STOCK_OUTPUT_DIR/preparation.json" >/dev/null
    test "$(python3 scripts/stock_cache.py cacheable --root "$BUILD_STOCK_OUTPUT_DIR")" = false
    test -z "$(find "$BUILD_STOCK_OUTPUT_DIR" -type f -size +104857600c -print)"
    BUILD_STOCK_ONLY=false BUILD_STOCK_DIR="$BUILD_STOCK_OUTPUT_DIR" \
      BUILD_PATCH_OUTPUT_DIR="$tmp/patch" bash -c 'source utils.sh; mkdir -p temp; import_stock_result "$1"; test "$PREPARED_STOCK_VERIFIED" = true' _ "$tmp/consumed.apk"
    test "$(wc -l < "$TEST_MERGES")" = 1
    jq -e '.mergeCount == 1 and .materializedBytes > 104857600' "$tmp/patch/materialization.json" >/dev/null
    jq -e '.crossSource.status == "not-required"' "$tmp/consumed.apk.security.json" >/dev/null
    python3 - "$BUILD_STOCK_OUTPUT_DIR" "$tmp/consumed.apk" "$BUILD_ARCH" <<'PY'
import sys, zipfile
from pathlib import Path
root, output, arch = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
expected = {'assets/base.apk.bin', 'assets/config.en.apk.bin'}
if arch in ('universal', 'arm64-v8a'): expected.add('assets/config.arm64.apk.bin')
if arch in ('universal', 'arm-v7a'): expected.add('assets/config.armv7.apk.bin')
with zipfile.ZipFile(output) as merged:
    assert set(merged.namelist()) == expected
    for split in (root / 'source').rglob('*.apk'):
        with zipfile.ZipFile(split) as source:
            for name in source.namelist():
                assert merged.read(name) == source.read(name)
print(f'{arch}: consumed {output.stat().st_size} bytes from verified deferred stock')
PY
    rm "$TEST_MERGES" "$TEST_SIGNERS"
  done
done

# Exercise completion independently of preparation: a stage returning success
# must not make an incomplete, stale or tampered handoff reusable.
printf '\nbuild_app() { return 0; }\n' >> utils.sh
export BUILD_STOCK_OUTPUT_DIR="$tmp/stock-partition-arm64-v8a" BUILD_ARCH=arm64-v8a
export BUILD_SOURCE_CACHE_KEY=stale-key
expect_failure_matching 'reject stale Source identity at completion' 1 'source policy mismatch' bash build.sh
export BUILD_SOURCE_CACHE_KEY=source-key BUILD_ARCH=arm-v7a
expect_failure_matching 'reject wrong architecture at completion' 1 'axes mismatch' bash build.sh
export BUILD_ARCH=arm64-v8a
printf tamper >> "$BUILD_STOCK_OUTPUT_DIR/source/common/base.apk"
expect_failure_matching 'reject changed deferred payload at completion' 1 'digest/size mismatch' bash build.sh
export BUILD_STOCK_OUTPUT_DIR="$tmp/incomplete"
mkdir -p "$BUILD_STOCK_OUTPUT_DIR"
printf apk > "$BUILD_STOCK_OUTPUT_DIR/stock.apk"
expect_failure_matching 'reject an APK without its contract' 1 'invalid cache metadata' bash build.sh

# Prepared schema-v1 output still completes after its existing validation.
export BUILD_STOCK_OUTPUT_DIR="$tmp/prepared"
printf '{"securityValidated":true,"artifactSha256":"%s","comparisonSha256":"%064d"}\n' \
  "$(sha256sum "$tmp/incomplete/stock.apk" | awk '{print toupper($1)}')" 1 > "$tmp/incomplete/stock.apk.security.json"
bash -c 'source utils.sh; CURRENT_STOCK_SOURCE=direct; export_stock_result "$1" com.example 1.0 arm64-v8a' _ "$tmp/incomplete/stock.apk"
bash build.sh > "$tmp/prepared.log" 2>&1 || { cat "$tmp/prepared.log"; exit 1; }
grep -q 'Prepared stock input' "$tmp/prepared.log"
export BUILD_STOCK_OUTPUT_DIR="$tmp/stock-branches-universal" BUILD_ARCH=universal
for gate in REJECT_SIGNER REJECT_SECURITY; do
  expect_failure_status "reject failed $gate at late consumption" 2 \
    env "$gate=true" BUILD_STOCK_ONLY=false BUILD_STOCK_DIR="$BUILD_STOCK_OUTPUT_DIR" \
    bash -c 'source utils.sh; import_stock_result "$1"' _ "$tmp/rejected.apk"
done
echo 'deferred stock entry point and consumer test passed (partition and branches)'
