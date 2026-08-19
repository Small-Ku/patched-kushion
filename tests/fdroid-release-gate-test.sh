#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/config.toml" <<'TOML'
[fdroid]
include-built-releases = true
max-repo-asset-size = 100
TOML
cat > "$tmp/publication.json" <<'JSON'
{"schemaVersion":1,"repository":"example/patched-kushion","releaseTag":"22","assets":[
  {"target":"KouPhotos","version":"7.89","arch":"arm64-v8a","mode":"apk","assetId":11,"assetName":"kouphotos-arm64.apk","size":90},
  {"target":"KouPhotos","version":"7.89","arch":"universal","mode":"apk","assetId":12,"assetName":"kouphotos-universal.apk","size":120},
  {"target":"KouPhotos","version":"7.89","arch":"arm64-v8a","mode":"module","assetId":13,"assetName":"kouphotos.zip","size":20}
]}
JSON
python3 "$root/scripts/fdroid_release_gate.py" --config "$tmp/config.toml" --publication "$tmp/publication.json" > "$tmp/out"
grep -Fq 'kouphotos-arm64.apk' "$tmp/out"
grep -Fq 'kouphotos-universal.apk' "$tmp/out"
grep -Fq 'changed=1' "$tmp/out"
jq '.assets = [.assets[] | select(.assetName == "kouphotos-universal.apk")]' "$tmp/publication.json" > "$tmp/oversized.json"
python3 "$root/scripts/fdroid_release_gate.py" --config "$tmp/config.toml" --publication "$tmp/oversized.json" > "$tmp/out2"
grep -Fq 'changed=0' "$tmp/out2"
sed -i 's/include-built-releases = true/include-built-releases = false/' "$tmp/config.toml"
python3 "$root/scripts/fdroid_release_gate.py" --config "$tmp/config.toml" --publication "$tmp/publication.json" > "$tmp/out3"
grep -Fq 'changed=0' "$tmp/out3"
echo 'F-Droid release handoff size gate test passed'
