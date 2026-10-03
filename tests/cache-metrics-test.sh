#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/payload"
printf payload > "$tmp/payload/file"
printf '{"mergeCount":1,"materializationSeconds":42}\n' > "$tmp/payload/materialization.json"
python3 scripts/cache_metrics.py start --clock "$tmp/clock"
python3 scripts/cache_metrics.py record --clock "$tmp/clock" --root "$tmp/payload" \
  --report "$tmp/report.json" --stage stock --operation restore --hit true
jq -e '.schemaVersion == 1 and .events[0].logicalBytes > 7 and .events[0].cacheHit == true and .events[0].actionSeconds >= 0 and .events[0].archiveBytes == null and .events[0].byteSemantics == "restored-directory"' "$tmp/report.json" >/dev/null
jq -e '.mergeCount == 0 and .materializationSeconds == 0' "$tmp/payload/materialization.json" >/dev/null
python3 scripts/cache_metrics.py start --clock "$tmp/clock"
python3 scripts/cache_metrics.py record --clock "$tmp/clock" --root "$tmp/missing" \
  --report "$tmp/report.json" --stage source --operation restore --hit false
jq -e '.events[1].logicalBytes == 0 and .events[1].cacheHit == false' "$tmp/report.json" >/dev/null
echo 'cache byte semantics and current-run materialization metrics test passed'
