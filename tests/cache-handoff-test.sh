#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/source/branches/arm64-v8a"
printf apk > "$tmp/source/branches/arm64-v8a/base.apk"
cat > "$tmp/source/source.json" <<'JSON'
{"schemaVersion":2,"status":"ready","strategy":"branches","version":"1.2.3","availableBuildArches":["arm64-v8a"],"coverage":{"missingRequired":[]}}
JSON
scripts/cache_handoff.py source --root "$tmp/source" --version 1.2.3

mkdir -p "$tmp/stock"
printf stock > "$tmp/stock/stock.apk"
stock_sha=$(sha256sum "$tmp/stock/stock.apk" | awk '{print toupper($1)}')
printf '%s\n' "{\"schemaVersion\":1,\"target\":\"App\",\"version\":\"1.2.3\",\"arch\":\"arm64-v8a\",\"sha256\":\"$stock_sha\",\"stockValidated\":true,\"securityValidated\":true,\"fingerprintSha256\":\"ABC\"}" > "$tmp/stock/stock.json"
printf '%s\n' "{\"artifactSha256\":\"$stock_sha\",\"comparisonSha256\":\"ABC\"}" > "$tmp/stock/stock.security.json"
scripts/cache_handoff.py stock --root "$tmp/stock" --target App --version 1.2.3 --arch arm64-v8a

mkdir -p "$tmp/patch"
printf patched > "$tmp/patch/patched.apk"
patch_sha=$(sha256sum "$tmp/patch/patched.apk" | awk '{print toupper($1)}')
printf '%s\n' "{\"schemaVersion\":1,\"target\":\"App\",\"version\":\"1.2.3\",\"arch\":\"arm64-v8a\",\"mode\":\"apk\",\"sha256\":\"$patch_sha\",\"patchProfileHash\":\"profile\"}" > "$tmp/patch/patch.json"
scripts/cache_handoff.py patch --root "$tmp/patch" --target App --version 1.2.3 --arch arm64-v8a --mode apk --profile profile

printf tamper >> "$tmp/patch/patched.apk"
if scripts/cache_handoff.py patch --root "$tmp/patch" --target App --version 1.2.3 --arch arm64-v8a --mode apk --profile profile 2>/dev/null; then
  echo "tampered patch cache unexpectedly validated" >&2
  exit 1
fi
