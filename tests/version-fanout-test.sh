#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/graph.json" <<'JSON'
{"kind":"source-acquisition-dag","versionTraversal":["3.0","2.0"],"versions":[{"version":"3.0","compatibility":"forward-probe"},{"version":"2.0","compatibility":"declared"}]}
JSON
mkdir -p "$tmp/status/a" "$tmp/status/b"
printf '%s\n' '{"version":"3.0","ready":true,"strategy":"partition","sourceKey":"fixture-3"}' > "$tmp/status/a/source-status.json"
printf '%s\n' '{"version":"2.0","ready":true,"strategy":"branches","sourceKey":"fixture-2"}' > "$tmp/status/b/source-status.json"
arches='[{"key":"fixture--arm64-v8a","arch":"arm64-v8a","optional":false,"sourcePriority":"required","variants":[{"key":"fixture--arm64-v8a--apk","mode":"apk","candidateInputIds":{"2.0":"known"},"inputBase":"base","forwardProbeLimit":2,"reuseByInputId":{},"optional":false,"sourcePriority":"required","sourcePolicyHash":"source-policy","patchProfileHash":"profile","patchAssetHash":"asset"}]}]'
out=$(scripts/version_fanout.py collect --graph "$tmp/graph.json" --statuses-root "$tmp/status" --arches-json "$arches")
[ "$(jq '.include|length' <<<"$out")" -eq 2 ]
[ "$(jq -r '.include[]|select(.version=="2.0")|.branch.variants[0].inputId' <<<"$out")" = known ]
forward=$(jq -r '.include[]|select(.version=="3.0")|.branch.variants[0].inputId' <<<"$out")
[ "${#forward}" -eq 64 ]
[ "$(jq -r '.include[]|select(.version=="3.0")|.branch.variants[0].compatibility' <<<"$out")" = forward-probe ]
[ "$(jq -r '.include[]|select(.version=="3.0")|.branch.variants[0].resultKey' <<<"$out")" != fixture--arm64-v8a--apk ]
[ "$(jq -r '.include[]|select(.version=="2.0")|.sourceCacheKey|length' <<<"$out")" -eq 64 ]
forward_reuse=$(python3 - <<'PY_REUSE'
import hashlib, json
value={"base":"base","version":"3.0","arch":"arm64-v8a","mode":"apk"}
raw=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
print(hashlib.sha256(raw).hexdigest())
PY_REUSE
)
arches_reuse=$(jq -c --arg forward "$forward_reuse" '.[0].variants[0].reuseByInputId={"known":{"inputId":"known","version":"2.0","assetId":20,"assetName":"fixture-2.apk","sha256":"AA","releaseTag":"9"},($forward):{"inputId":$forward,"version":"3.0","assetId":30,"assetName":"fixture-3.apk","sha256":"BB","releaseTag":"9"}}' <<<"$arches")
candidates=$(scripts/version_fanout.py candidates --graph "$tmp/graph.json" --arches-json "$arches_reuse")
[ "$(jq '[.[]|select(.allReusable==true)]|length' <<<"$candidates")" -eq 2 ]
source_cache=$(jq -r '.[]|select(.version=="2.0")|.sourceCacheKey' <<<"$candidates")
[ "${#source_cache}" -eq 64 ]

pruned_candidates=$(scripts/version_fanout.py candidates \
  --graph "$tmp/graph.json" --arches-json "$arches_reuse" \
  --prune-reuse --reuse-statuses-output "$tmp/reused-status" --target-key fixture)
[ "$(jq 'length' <<<"$pruned_candidates")" -eq 0 ]
[ "$(find "$tmp/reused-status" -name source-status.json | wc -l)" -eq 2 ]
rm -rf "$tmp/status-pruned"; mkdir -p "$tmp/status-pruned"
cp -a "$tmp/reused-status/." "$tmp/status-pruned/"
pruned=$(scripts/version_fanout.py collect \
  --graph "$tmp/graph.json" --statuses-root "$tmp/status-pruned" --arches-json "$arches_reuse" \
  --prune-reuse --reuse-output "$tmp/reuse.json" --target Fixture)
[ "$(jq '.include|length' <<<"$pruned")" -eq 0 ]
[ "$(jq '.reused|length' "$tmp/reuse.json")" -eq 2 ]
scripts/write-reuse-results.py --manifest "$tmp/reuse.json" --output-dir "$tmp/reuse-results"
[ "$(find "$tmp/reuse-results" -name result.json | wc -l)" -eq 2 ]
jq -e '.target=="Fixture" and .reused==true and .sourceAssetId==20 and .version=="2.0"' \
  "$tmp/reuse-results/fixture--arm64-v8a--apk--2.0-d84bdb34/result.json" >/dev/null

arches_patch_changed=$(jq -c '.[0].variants[0].patchAssetHash="different-patch"' <<<"$arches_reuse")
source_cache_after_patch=$(scripts/version_fanout.py candidates --graph "$tmp/graph.json" --arches-json "$arches_patch_changed" | jq -r '.[]|select(.version=="2.0")|.sourceCacheKey')
[ "$source_cache_after_patch" = "$source_cache" ]

echo 'version fanout test passed'
