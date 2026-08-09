#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/build"
cat > "$tmp/build/skip.json" <<'JSON'
{"schemaVersion":1,"reason":"fixture ABI unavailable"}
JSON
python3 "$root/scripts/write-build-result.py" \
  --key fixture--x86--apk \
  --input-id input123 \
  --target Fixture \
  --arch x86 \
  --mode apk \
  --build-dir "$tmp/build" \
  --output-dir "$tmp/result"
jq -e '.skipped == true and .reason == "fixture ABI unavailable" and .arch == "x86"' "$tmp/result/result.json" >/dev/null
test ! -e "$tmp/result/fixture.apk"
echo 'optional build-result skip test passed'
