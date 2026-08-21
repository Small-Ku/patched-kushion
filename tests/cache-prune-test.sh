#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/graph.json" <<'JSON'
{"kind":"source-acquisition-dag","versionTraversal":["2.0"],"versions":[{"version":"2.0","compatibility":"declared"}]}
JSON
arches='[{"key":"fixture--arm64-v8a","arch":"arm64-v8a","optional":false,"sourcePriority":"required","stockPolicyHash":"stock-policy","variants":[{"key":"fixture--arm64-v8a--apk","mode":"apk","candidateInputIds":{"2.0":"known"},"inputBase":"base","forwardProbeLimit":0,"reuseByInputId":{},"optional":false,"sourcePriority":"required","sourcePolicyHash":"source-policy","patchProfileHash":"profile","patchAssetHash":"asset"}]}]'
candidates=$(scripts/version_fanout.py candidates --graph "$tmp/graph.json" --arches-json "$arches")
source_cache=$(jq -r '.[0].sourceCacheKey' <<<"$candidates")
version_key=$(jq -r '.[0].versionKey' <<<"$candidates")
impl=impl-hash
source_impl=source-impl-hash
cache_key="patched-kushion-stock-v2-fixture--arm64-v8a--${version_key}-${source_cache}-stock-policy-${impl}"
jq -n --arg key "$cache_key" '{actions_caches:[{key:$key,ref:"refs/heads/main"}]}' > "$tmp/caches.json"
out=$(scripts/cache_prune.py \
  --candidates-json "$candidates" \
  --arches-json "$arches" \
  --source-impl-hash "$source_impl" \
  --stock-impl-hash "$impl" \
  --target-key fixture \
  --statuses-output "$tmp/statuses" \
  --report-output "$tmp/report.json" \
  --cache-list-file "$tmp/caches.json")
[ "$(jq 'length' <<<"$out")" -eq 0 ]
status="$tmp/statuses/$version_key/source-status.json"
jq -e '.ready==true and .strategy=="stock-cache" and .acquisitionOutcome=="planner-stock-cache"' "$status" >/dev/null
jq -e --arg key "$cache_key" '.diagnostics.stockCacheKeys == [$key]' "$status" >/dev/null
jq -e '.candidates[0].pruned==true and (.candidates[0].stockCacheHits|length)==1' "$tmp/report.json" >/dev/null

printf '%s\n' '{"actions_caches":[]}' > "$tmp/miss.json"
miss=$(scripts/cache_prune.py \
  --candidates-json "$candidates" \
  --arches-json "$arches" \
  --source-impl-hash "$source_impl" \
  --stock-impl-hash "$impl" \
  --target-key fixture \
  --statuses-output "$tmp/miss-statuses" \
  --cache-list-file "$tmp/miss.json")
[ "$(jq 'length' <<<"$miss")" -eq 1 ]
[ ! -e "$tmp/miss-statuses/$version_key/source-status.json" ]

source_key="patched-kushion-source-v2-fixture-${source_cache}-${source_impl}"
jq -n --arg key "$source_key" '{actions_caches:[{key:$key,ref:"refs/heads/main"}]}' > "$tmp/source-cache.json"
source_pruned=$(scripts/cache_prune.py \
  --candidates-json "$candidates" \
  --arches-json "$arches" \
  --source-impl-hash "$source_impl" \
  --stock-impl-hash "$impl" \
  --target-key fixture \
  --statuses-output "$tmp/source-statuses" \
  --cache-list-file "$tmp/source-cache.json")
[ "$(jq 'length' <<<"$source_pruned")" -eq 0 ]
jq -e '.strategy=="source-cache" and .acquisitionOutcome=="planner-source-cache"' "$tmp/source-statuses/$version_key/source-status.json" >/dev/null

multi_arches=$(jq -c '. + [{key:"fixture--x86",arch:"x86",optional:false,sourcePriority:"required",stockPolicyHash:"stock-policy-x86",variants:[(. [0].variants[0] | .key="fixture--x86--apk")]}]' <<<"$arches")
multi_candidates=$(scripts/version_fanout.py candidates --graph "$tmp/graph.json" --arches-json "$multi_arches")
multi_source_only=$(scripts/cache_prune.py \
  --candidates-json "$multi_candidates" \
  --arches-json "$multi_arches" \
  --source-impl-hash "$source_impl" \
  --stock-impl-hash "$impl" \
  --target-key fixture \
  --statuses-output "$tmp/multi-statuses" \
  --cache-list-file "$tmp/source-cache.json")
[ "$(jq 'length' <<<"$multi_source_only")" -eq 1 ]

# A branch that is already release-reusable must not demand a stock cache hit.
reuse_arches=$(jq -c '.[0].variants[0].reuseByInputId={"known":{"inputId":"known","version":"2.0","assetId":9,"assetName":"fixture.apk","sha256":"AA","releaseTag":"9"}}' <<<"$arches")
reuse_candidates=$(scripts/version_fanout.py candidates --graph "$tmp/graph.json" --arches-json "$reuse_arches" --prune-reuse --reuse-statuses-output "$tmp/reuse-status" --target-key fixture)
[ "$(jq 'length' <<<"$reuse_candidates")" -eq 0 ]

echo 'planner stock-cache pruning test passed'
