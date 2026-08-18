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
arches='[{"key":"fixture--arm64-v8a","arch":"arm64-v8a","optional":false,"sourcePriority":"required","variants":[{"key":"fixture--arm64-v8a--apk","arch":"arm64-v8a","mode":"apk","candidateInputIds":{"2.0":"known"},"inputBase":"base","forwardProbeLimit":2,"reuseByInputId":{},"optional":false,"sourcePriority":"required","patchProfileHash":"profile","patchAssetHash":"asset"}]}]'
out=$(scripts/version_fanout.py collect --graph "$tmp/graph.json" --statuses-root "$tmp/status" --arches-json "$arches")
[ "$(jq '.include|length' <<<"$out")" -eq 2 ]
[ "$(jq -r '.include[]|select(.version=="2.0")|.branch.variants[0].inputId' <<<"$out")" = known ]
forward=$(jq -r '.include[]|select(.version=="3.0")|.branch.variants[0].inputId' <<<"$out")
[ "${#forward}" -eq 64 ]
[ "$(jq -r '.include[]|select(.version=="3.0")|.branch.variants[0].compatibility' <<<"$out")" = forward-probe ]
[ "$(jq -r '.include[]|select(.version=="3.0")|.branch.variants[0].resultKey' <<<"$out")" != fixture--arm64-v8a--apk ]
forward_reuse=$(python3 - <<'PY_REUSE'
import hashlib, json
value={"base":"base","version":"3.0","arch":"arm64-v8a","mode":"apk"}
raw=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
print(hashlib.sha256(raw).hexdigest())
PY_REUSE
)
arches_reuse=$(jq -c --arg forward "$forward_reuse" '.[0].variants[0].reuseByInputId={"known":{"inputId":"known"},($forward):{"inputId":$forward}}' <<<"$arches")
candidates=$(scripts/version_fanout.py candidates --graph "$tmp/graph.json" --arches-json "$arches_reuse")
[ "$(jq '[.[]|select(.allReusable==true)]|length' <<<"$candidates")" -eq 2 ]

echo 'version fanout test passed'
