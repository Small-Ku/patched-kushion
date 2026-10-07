#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
# shellcheck disable=SC1091
source "$root/tests/testlib.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"

# -----------------------------------------------------------------------------
# Helper: Create test APKs and bundles
# -----------------------------------------------------------------------------
python3 - "$tmp" <<'PY'
import io, sys, zipfile
from pathlib import Path

root = Path(sys.argv[1])

def make_apk(libs=(), padding=1024):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as z:
        z.writestr('AndroidManifest.xml', b'manifest')
        for abi in libs:
            z.writestr(f'lib/{abi}/libsample.so', b'x' * padding)
        if not libs:
            z.writestr('assets/data.bin', b'd' * padding)
    return out.getvalue()

def make_bundle(path, items):
    with zipfile.ZipFile(path, 'w') as z:
        for name, libs, padding in items:
            z.writestr(name, make_apk(libs, padding))

# YouTube 21.36.47 arm-v7a fixture:
# A broad split bundle with multiple ABIs and configuration splits.
# Container size has ~160KB payload, but arm-v7a size estimate excludes foreign ABIs.
make_bundle(root / 'youtube-broad.apkm', [
    ('base.apk', (), 40960),
    ('split_config.arm64_v8a.apk', ('arm64-v8a',), 30720),
    ('split_config.armeabi_v7a.apk', ('armeabi-v7a',), 20480),
    ('split_config.x86.apk', ('x86',), 25600),
    ('split_config.x86_64.apk', ('x86_64',), 25600),
    ('split_config.en.apk', (), 5120),
    ('split_config.fr.apk', (), 5120),
    ('split_config.xxhdpi.apk', (), 10240),
])

# Instagram 439 arm64 fixture:
# Split bundle where density split is required, resulting in 0% minimal savings.
make_bundle(root / 'instagram-arm64.apkm', [
    ('base.apk', (), 51200),
    ('split_config.arm64_v8a.apk', ('arm64-v8a',), 20480),
    ('split_config.xxhdpi.apk', (), 30720),
])

# Google Photos 7.89 fixture:
# Flattened universal APK with 4 ABIs; cannot derive per-ABI.
with open(root / 'photos-universal.apk', 'wb') as f:
    f.write(make_apk(('arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'), 20480))

# Standalone APKs for comparison
with open(root / 'standalone-armv7-130k.apk', 'wb') as f:
    f.write(make_apk(('armeabi-v7a',), 133120))

with open(root / 'standalone-arm64-80k.apk', 'wb') as f:
    f.write(make_apk(('arm64-v8a',), 81920))

with open(root / 'standalone-arm64-100k.apk', 'wb') as f:
    f.write(make_apk(('arm64-v8a',), 102400))
PY

# -----------------------------------------------------------------------------
# Test 1: source_candidate_score ranking hierarchy
# -----------------------------------------------------------------------------
mkdir -p "$tmp/score-manifests"
cat > "$tmp/score-manifests/direct-150m.json" <<'EOF'
{
  "strategy": "partition",
  "availableBuildArches": ["arm64-v8a", "arm-v7a"],
  "coverage": {
    "required": ["arm64-v8a"],
    "desired": ["arm64-v8a"],
    "optional": [],
    "missingRequired": [],
    "missingDesired": [],
    "missingOptional": []
  },
  "estimatedStandaloneBytes": 150000000,
  "selection": {"artifactCount": 1}
}
EOF

cat > "$tmp/score-manifests/apkpure-90m.json" <<'EOF'
{
  "strategy": "partition",
  "availableBuildArches": ["arm64-v8a", "arm-v7a"],
  "coverage": {
    "required": ["arm64-v8a"],
    "desired": ["arm64-v8a"],
    "optional": [],
    "missingRequired": [],
    "missingDesired": [],
    "missingOptional": []
  },
  "estimatedStandaloneBytes": 90000000,
  "selection": {"artifactCount": 1}
}
EOF

cat > "$tmp/score-manifests/direct-90m.json" <<'EOF'
{
  "strategy": "partition",
  "availableBuildArches": ["arm64-v8a", "arm-v7a"],
  "coverage": {
    "required": ["arm64-v8a"],
    "desired": ["arm64-v8a"],
    "optional": [],
    "missingRequired": [],
    "missingDesired": [],
    "missingOptional": []
  },
  "estimatedStandaloneBytes": 90000000,
  "selection": {"artifactCount": 1}
}
EOF

cat > "$tmp/score-manifests/branches-80m.json" <<'EOF'
{
  "strategy": "branches",
  "availableBuildArches": ["arm64-v8a", "arm-v7a"],
  "coverage": {
    "required": ["arm64-v8a"],
    "desired": ["arm64-v8a"],
    "optional": [],
    "missingRequired": [],
    "missingDesired": [],
    "missingOptional": []
  },
  "estimatedStandaloneBytes": 80000000,
  "downloadPlan": {"artifactCount": 2}
}
EOF

# 1a. Lower estimated standalone bytes beats higher provider priority
score_direct_150m=$(source_candidate_score "$tmp/score-manifests/direct-150m.json" direct)
score_apkpure_90m=$(source_candidate_score "$tmp/score-manifests/apkpure-90m.json" apkpure)
[ "$score_apkpure_90m" -gt "$score_direct_150m" ]

# 1b. Provider priority breaks exact size ties
score_direct_90m=$(source_candidate_score "$tmp/score-manifests/direct-90m.json" direct)
[ "$score_direct_90m" -gt "$score_apkpure_90m" ]

# 1c. Usable partition topology beats branches strategy even if branches has smaller size
score_branches_80m=$(source_candidate_score "$tmp/score-manifests/branches-80m.json" direct)
[ "$score_direct_150m" -gt "$score_branches_80m" ]

echo "source_candidate_score tests passed"

# -----------------------------------------------------------------------------
# Test 2: branch_source_candidate_score ranking hierarchy
# -----------------------------------------------------------------------------
mkdir -p "$tmp/branch-candidates/b-bundle-120m" "$tmp/branch-candidates/b-bundle-80m" \
         "$tmp/branch-candidates/b-bundle-80m-pure" "$tmp/branch-candidates/b-apk-70m"

cat > "$tmp/branch-candidates/b-bundle-120m/branch.json" <<'EOF'
{"available": true, "arch": "arm64-v8a", "format": "BUNDLE", "estimatedStandaloneBytes": 120000000}
EOF

cat > "$tmp/branch-candidates/b-bundle-80m/branch.json" <<'EOF'
{"available": true, "arch": "arm64-v8a", "format": "BUNDLE", "estimatedStandaloneBytes": 80000000}
EOF

cat > "$tmp/branch-candidates/b-bundle-80m-pure/branch.json" <<'EOF'
{"available": true, "arch": "arm64-v8a", "format": "BUNDLE", "estimatedStandaloneBytes": 80000000}
EOF

cat > "$tmp/branch-candidates/b-apk-70m/branch.json" <<'EOF'
{"available": true, "arch": "arm64-v8a", "format": "APK", "estimatedStandaloneBytes": 70000000}
EOF

# 2a. Usable topology: BUNDLE beats standalone APK even if APK has smaller size
bscore_bundle_120m=$(branch_source_candidate_score "$tmp/branch-candidates/b-bundle-120m" direct BUNDLE)
bscore_apk_70m=$(branch_source_candidate_score "$tmp/branch-candidates/b-apk-70m" direct APK)
[ "$bscore_bundle_120m" -gt "$bscore_apk_70m" ]

# 2b. Within same topology, lower estimated bytes beats provider preference
bscore_bundle_80m_pure=$(branch_source_candidate_score "$tmp/branch-candidates/b-bundle-80m-pure" apkpure BUNDLE)
[ "$bscore_bundle_80m_pure" -gt "$bscore_bundle_120m" ]

# 2c. Provider tie-breaker when estimated sizes are equal
bscore_bundle_80m_direct=$(branch_source_candidate_score "$tmp/branch-candidates/b-bundle-80m" direct BUNDLE)
[ "$bscore_bundle_80m_direct" -gt "$bscore_bundle_80m_pure" ]

echo "branch_source_candidate_score tests passed"

# -----------------------------------------------------------------------------
# Test 3: Reject APKs that cannot build the requested ABI (Google Photos 7.89 case)
# -----------------------------------------------------------------------------
# Google Photos flattened multi-ABI APK cannot derive per-ABI (x86_64, arm-v7a, etc.)
expect_failure_matching \
  'flattened multi-ABI APK cannot derive per-ABI x86_64' 1 \
  'cannot derive per-ABI' \
  python3 "$root/scripts/stock_bundle.py" estimate-size --apk "$tmp/photos-universal.apk" --arch x86_64

expect_failure_matching \
  'flattened multi-ABI APK cannot derive per-ABI arm-v7a' 1 \
  'cannot derive per-ABI' \
  python3 "$root/scripts/stock_bundle.py" estimate-size --apk "$tmp/photos-universal.apk" --arch arm-v7a

# Single-ABI APK cannot derive universal
expect_failure_matching \
  'single-ABI APK cannot derive universal' 1 \
  'single-ABI APK cannot derive universal' \
  python3 "$root/scripts/stock_bundle.py" estimate-size --apk "$tmp/standalone-arm64-80k.apk" --arch universal

echo "requested ABI rejection tests passed"

# -----------------------------------------------------------------------------
# Test 4: YouTube 21.36.47 arm-v7a multi-ABI container size estimate
# -----------------------------------------------------------------------------
# Total container size contains 8 splits (~163KB).
# Projecting arm-v7a drops 3 foreign ABI splits (arm64, x86, x86_64).
python3 "$root/scripts/stock_bundle.py" estimate-size --bundle "$tmp/youtube-broad.apkm" --arch arm-v7a > "$tmp/yt-armv7-estimate.json"

[ "$(jq -r .arch "$tmp/yt-armv7-estimate.json")" = 'arm-v7a' ]
[ "$(jq -r .format "$tmp/yt-armv7-estimate.json")" = 'BUNDLE' ]
[ "$(jq -r .topology "$tmp/yt-armv7-estimate.json")" = 'split-bundle' ]
[ "$(jq -r .canBuildRequestedArch "$tmp/yt-armv7-estimate.json")" = 'true' ]
[ "$(jq -r .sizeEstimateBasis "$tmp/yt-armv7-estimate.json")" = 'preserve-split-set' ]
[ "$(jq -r .sizeEstimatePolicy "$tmp/yt-armv7-estimate.json")" = 'preserve' ]

# Selected split count must be 5 (base + armv7 + en + fr + xxhdpi), omitted 3 foreign ABIs
[ "$(jq -r '.sizeEstimateEvidence.selectedSplitCount' "$tmp/yt-armv7-estimate.json")" -eq 5 ]
[ "$(jq -r '.sizeEstimateEvidence.totalSplitCount' "$tmp/yt-armv7-estimate.json")" -eq 8 ]

yt_estimated_bytes=$(jq -r .estimatedStandaloneBytes "$tmp/yt-armv7-estimate.json")
# Estimated bytes must be less than total member bytes (which includes foreign ABIs)
yt_total_bytes=$(jq -r '.sizeEstimateEvidence.totalMemberBytes' "$tmp/yt-armv7-estimate.json")
[ "$yt_estimated_bytes" -lt "$yt_total_bytes" ]

# Standalone 130KB APK has larger standalone bytes
standalone_130k_bytes=$(stat -c %s "$tmp/standalone-armv7-130k.apk" 2>/dev/null || stat -f %z "$tmp/standalone-armv7-130k.apk")
[ "$yt_estimated_bytes" -lt "$standalone_130k_bytes" ]

echo "YouTube 21.36.47 arm-v7a size estimate test passed"

# -----------------------------------------------------------------------------
# Test 5: Instagram 439 arm64 required density split (0% minimal savings)
# -----------------------------------------------------------------------------
python3 "$root/scripts/stock_bundle.py" estimate-size --bundle "$tmp/instagram-arm64.apkm" --arch arm64-v8a > "$tmp/ig-arm64-estimate.json"

[ "$(jq -r .arch "$tmp/ig-arm64-estimate.json")" = 'arm64-v8a' ]
[ "$(jq -r '.sizeEstimateEvidence.selectedSplitCount' "$tmp/ig-arm64-estimate.json")" -eq 3 ]
[ "$(jq -r '.sizeEstimateEvidence.totalSplitCount' "$tmp/ig-arm64-estimate.json")" -eq 3 ]
# All splits preserved: base, arm64, xxhdpi
ig_estimated_bytes=$(jq -r .estimatedStandaloneBytes "$tmp/ig-arm64-estimate.json")
ig_total_bytes=$(jq -r '.sizeEstimateEvidence.totalMemberBytes' "$tmp/ig-arm64-estimate.json")
[ "$ig_estimated_bytes" -eq "$ig_total_bytes" ]
[ "$(jq -r '.sizeEstimateEvidence.minimalSavingsBytes' "$tmp/ig-arm64-estimate.json")" -eq 0 ]

echo "Instagram 439 arm64 size estimate test passed"

# -----------------------------------------------------------------------------
# Test 6: add_branch_size_estimate & add_source_size_estimates handoffs
# -----------------------------------------------------------------------------
mkdir -p "$tmp/test-branch/splits"
python3 "$root/scripts/stock_bundle.py" select --bundle "$tmp/youtube-broad.apkm" --arch arm-v7a --output-dir "$tmp/test-branch/splits" >/dev/null
cat > "$tmp/test-branch/branch.json" <<'EOF'
{"schemaVersion": 1, "arch": "arm-v7a", "format": "BUNDLE", "available": true}
EOF

add_branch_size_estimate "$tmp/test-branch" arm-v7a
jq -e '.estimatedStandaloneBytes > 0 and .sizeEstimateBasis == "preserve-split-set" and .sizeEstimatePolicy == "preserve" and .sizeEstimateEvidence.selectedSplitCount == 5' "$tmp/test-branch/branch.json" >/dev/null

mkdir -p "$tmp/test-source/branches/arm-v7a"
cp -f "$tmp/test-branch/branch.json" "$tmp/test-source/branches/arm-v7a/branch.json"
cat > "$tmp/test-source/source.json" <<'EOF'
{
  "schemaVersion": 2,
  "status": "ready",
  "strategy": "branches",
  "availableBuildArches": ["arm-v7a"],
  "coverage": {"required": ["arm-v7a"], "available": ["arm-v7a"], "missingRequired": []}
}
EOF

add_source_size_estimates "$tmp/test-source/source.json" '[{"arch":"arm-v7a"}]'
jq -e '.estimatedStandaloneBytes > 0 and .sizeEstimateBasis == "split-bundle" and .sizeEstimatePolicy == "preserve" and .sizeEstimates["arm-v7a"].estimatedStandaloneBytes > 0 and .sizeEstimates["arm-v7a"].sizeEstimatePolicy == "preserve"' "$tmp/test-source/source.json" >/dev/null

echo "handoff evidence annotation tests passed"

# -----------------------------------------------------------------------------
# Test 7: End-to-end branch source selection with estimated standalone APK size
# -----------------------------------------------------------------------------
declare -A args
args[direct_dlurl]="https://example.invalid/direct"
args[apkpure_dlurl]="https://example.invalid/apkpure"
BUILD_SOURCE_OUTPUT_DIR="$tmp/branch-out"
BUILD_TARGET=Fixture

# Mock network & verification functions
check_sig() { return 0; }
acquisition_source_resp() { return 0; }
get_direct_resp() { return 0; }
get_apkpure_resp() { return 0; }
validate_optional_auto_abi() { return 0; }

dl_direct() {
  local _url=$1 _version=$2 output=$3 _arch=$4
  cp -f "$tmp/standalone-arm64-100k.apk" "$output"
}

dl_apkpure() {
  local _url=$1 _version=$2 output=$3 _arch=$4
  cp -f "$tmp/standalone-arm64-80k.apk" "$output"
}

# When evaluating arm64-v8a: Direct (100KB) vs APKPure (80KB).
# APKPure has lower provider priority than Direct, but smaller estimated standalone APK size.
# Therefore APKPure must win!
prepare_branch_stock_sources com.example 1.0 '' '[{"arch":"arm64-v8a","optional":false}]'

jq -e '.sourceName == "apkpure"' "$tmp/branch-out/source.json" >/dev/null
jq -e '.estimatedStandaloneBytes < 100000' "$tmp/branch-out/source.json" >/dev/null
jq -e '.sizeEstimates["arm64-v8a"].estimatedStandaloneBytes < 100000' "$tmp/branch-out/source.json" >/dev/null
[ -f "$tmp/branch-out/branches/arm64-v8a/branch.json" ]
[ "$(jq -r .sourceName "$tmp/branch-out/branches/arm64-v8a/branch.json")" = 'apkpure' ]
[ "$(jq -r .estimatedStandaloneBytes "$tmp/branch-out/branches/arm64-v8a/branch.json")" -lt 100000 ]

echo "end-to-end branch size selection test passed"
echo "ALL source size ranking tests passed successfully!"
