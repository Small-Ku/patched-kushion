#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sources/source-one" "$tmp/results/result-one" "$tmp/release"

cat > "$tmp/plan.json" <<'JSON'
{
  "schemaVersion": 1,
  "releaseTag": "42",
  "generation": "feedfacecafebeef",
  "availability": [
    {"target":"KouPhotos","versionCandidates":["7.89"],"archPolicy":"auto","availableArches":["universal","arm64-v8a"],"optionalArches":["arm64-v8a"]}
  ],
  "matrix": [{"target":"KouPhotos","version":"7.89"}],
  "desired": [
    {"key":"kouphotos--universal--apk","target":"KouPhotos","version":"7.89","arch":"universal","mode":"apk","optional":false,"satisfied":false},
    {"key":"kouphotos--arm64-v8a--apk","target":"KouPhotos","version":"7.89","arch":"arm64-v8a","mode":"apk","optional":true,"satisfied":false}
  ]
}
JSON
cat > "$tmp/sources/source-one/source-status.json" <<'JSON'
{"schemaVersion":1,"target":"KouPhotos","version":"7.89","compatibility":"declared","ready":false,"acquisitionOutcome":"unavailable","exitCode":1}
JSON
cat > "$tmp/results/result-one/result.json" <<'JSON'
{"schemaVersion":1,"status":"failed","failed":true,"reason":"patch stage exited 1","key":"kouphotos--universal--apk--7.89","variantKey":"kouphotos--universal--apk","target":"KouPhotos","version":"7.89","arch":"universal","mode":"apk"}
JSON
cat > "$tmp/release/publication-status.json" <<'JSON'
{"schemaVersion":1,"releaseTag":"42","complete":false,"pending":["kouphotos--universal--apk"],"pendingDetails":[{"key":"kouphotos--universal--apk","target":"KouPhotos","version":"7.89","arch":"universal","mode":"apk","category":"build-failed","reason":"patch stage exited 1"}]}
JSON
cat > "$tmp/release/published-assets.json" <<'JSON'
{"schemaVersion":1,"assets":[{"target":"KouPhotos","version":"7.89","arch":"arm64-v8a","mode":"apk","assetName":"kouphotos-arm64.apk","size":85932428}]}
JSON
cat > "$tmp/before.json" <<'JSON'
{"schemaVersion":1,"packages":[]}
JSON
cat > "$tmp/after.json" <<'JSON'
{"schemaVersion":1,"packages":[{"source":"github","repository":"Small-Ku/patched-kushion","assetId":123,"packageName":"de.kwoo.shion.photos","versionName":"7.89","nativeCodes":["arm64-v8a"],"assetName":"kouphotos-arm64.apk","assetSize":85932428}]}
JSON

python3 scripts/ci_summary.py plan --plan "$tmp/plan.json" --no-github-summary > "$tmp/plan.md"
python3 scripts/ci_summary.py source --status "$tmp/sources/source-one/source-status.json" --no-github-summary > "$tmp/source.md"
python3 scripts/ci_summary.py variant --result "$tmp/results/result-one/result.json" --no-github-summary > "$tmp/variant.md"
python3 scripts/ci_summary.py release --plan "$tmp/plan.json" --status "$tmp/release/publication-status.json" --assets "$tmp/release/published-assets.json" --no-github-summary > "$tmp/release.md"
python3 scripts/ci_summary.py fdroid --before "$tmp/before.json" --after "$tmp/after.json" --json "$tmp/fdroid.json" --no-github-summary > "$tmp/fdroid.md"
python3 scripts/ci_summary.py pipeline \
  --plan "$tmp/plan.json" \
  --source-root "$tmp/sources" \
  --result-root "$tmp/results" \
  --publication-status "$tmp/release/publication-status.json" \
  --published-assets "$tmp/release/published-assets.json" \
  --fdroid-summary "$tmp/fdroid.json" \
  --plan-result success \
  --build-result success \
  --release-result success \
  --fdroid-check-result success \
  --fdroid-result success \
  --fdroid-changed 1 \
  --json "$tmp/pipeline.json" \
  --no-github-summary > "$tmp/pipeline.md"

grep -Fq 'Build plan' "$tmp/plan.md"
grep -Fq 'acquisition exit' "$tmp/source.md"
grep -Fq 'patch stage exited 1' "$tmp/variant.md"
grep -Fq 'Pending required variants' "$tmp/release.md"
grep -Fq 'kouphotos-arm64.apk' "$tmp/release.md"
grep -Fq 'de.kwoo.shion.photos' "$tmp/fdroid.md"
grep -Fq 'Publication needs attention.' "$tmp/pipeline.md"
grep -Fq 'patch stage exited 1' "$tmp/pipeline.md"
jq -e '.ok == false and .jobResults.plan == "success" and .variantCounts.pending == 1 and ((.fdroid.added | length) == 1)' "$tmp/pipeline.json" >/dev/null

python3 scripts/write-variant-failure.py \
  --variant-json '{"key":"fixture--arm64-v8a--apk","resultKey":"fixture-result","mode":"apk","inputId":"input-1"}' \
  --target Fixture \
  --arch arm64-v8a \
  --version 1.0 \
  --status-file "$tmp/results/result-one/result.json" \
  --output-dir "$tmp/failure-result"
jq -e '.status == "failed" and .failed == true and .variantKey == "fixture--arm64-v8a--apk" and .reason == "patch stage exited 1"' "$tmp/failure-result/result.json" >/dev/null

echo '[PASS] CI summaries expose stage outcomes, pending reasons, release assets, and F-Droid deltas'
