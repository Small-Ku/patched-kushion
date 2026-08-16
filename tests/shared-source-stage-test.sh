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
jq -e '.shared == true and .sourceName == "direct" and .trustClass == "configured-direct" and .sourceProvenanceFamily == "direct" and .sourceProvenanceDomain == "example.invalid" and .signerVerified == true and .availableBuildArches == ["universal","arm64-v8a","arm-v7a"]' "$tmp/out/source.json" >/dev/null
test -f "$tmp/out/common/base.apk"
test -f "$tmp/out/common/split_config.en.apk"
test -f "$tmp/out/abi/arm64-v8a/split_config.arm64_v8a.apk"
test -f "$tmp/out/abi/arm-v7a/split_config.armeabi_v7a.apk"
test -f "$tmp/out/abi/x86/availability.json"

# Universal is a materialization of every ABI present in the selected container,
# not a fifth upstream ABI. A broad ARM-only bundle therefore still satisfies a
# required universal branch.
prepare_shared_stock_source com.example 1.0 '' '[{"arch":"universal","optional":false}]'
jq -e '.shared == true and (.availableBuildArches | index("universal") != null)' "$tmp/out/source.json" >/dev/null

# A broad container may be reused with optional missing capabilities, but it
# must not be accepted when a configured architecture is required.
prepare_shared_stock_source com.example 1.0 '' '[{"arch":"x86","optional":false}]'
jq -e '.shared == false' "$tmp/out/source.json" >/dev/null
prepare_shared_stock_source com.example 1.0 '' '[{"arch":"x86","optional":true}]'
jq -e '.shared == false and .coverage.missingDesired == ["x86"]' "$tmp/out/source.json" >/dev/null


# A broad single-ABI APK is reusable for that ABI, but must not masquerade as
# universal. This is the APKPure case that previously triggered a broad request
# followed by redundant per-ABI downloads because the broad result was discarded.
python3 - "$tmp/armv7.apk" <<'PY_APK'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('AndroidManifest.xml', b'manifest')
    z.writestr('lib/armeabi-v7a/libx.so', b'x')
PY_APK
printf '%s\n' '{"schemaVersion":1,"source":"apkpure","version":"1.0","format":"APK"}' > "$tmp/armv7.apk.source.json"
args[apkpure_dlurl]="https://example.invalid/apkpure"
prepare_generic_shared_payload apkpure "$tmp/armv7.apk" com.example 1.0 \
  '[{"arch":"universal","optional":true,"sourcePriority":"desired"},{"arch":"arm-v7a","optional":true,"sourcePriority":"desired"}]' "$tmp/apk-out"
jq -e '.status == "ready" and .strategy == "branches" and .availableBuildArches == ["arm-v7a"] and .coverage.missingDesired == ["universal"]' "$tmp/apk-out/source.json" >/dev/null

# Candidate scoring is based on requested capability coverage, not unrelated
# ABIs a container happens to expose. Covering desired branches must dominate
# source preference and transfer-size tie breakers.
mkdir -p "$tmp/score-a" "$tmp/score-b"
cat > "$tmp/score-a/source.json" <<'JSON_SCORE_A'
{"strategy":"partition","availableBuildArches":["arm-v7a","x86","x86_64"],"coverage":{"required":[],"desired":["arm-v7a","arm64-v8a"],"optional":[],"missingRequired":[],"missingDesired":["arm64-v8a"],"missingOptional":[]},"selection":{"artifactCount":1}}
JSON_SCORE_A
cat > "$tmp/score-b/source.json" <<'JSON_SCORE_B'
{"strategy":"branches","availableBuildArches":["arm-v7a","arm64-v8a"],"coverage":{"required":[],"desired":["arm-v7a","arm64-v8a"],"optional":[],"missingRequired":[],"missingDesired":[],"missingOptional":[]},"selection":{"artifactCount":1}}
JSON_SCORE_B
score_a=$(source_candidate_score "$tmp/score-a/source.json" direct)
score_b=$(source_candidate_score "$tmp/score-b/source.json" apkpure)
[ "$score_b" -gt "$score_a" ]

echo 'shared source stage test passed'
