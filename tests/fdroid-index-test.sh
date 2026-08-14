#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/provenance.json" <<'JSON'
{"schemaVersion":3,"packages":[
{"source":"sing-box","repository":"SagerNet/sing-box","assetId":101,"packageName":"io.nekohasekai.sfa","versionCode":"100","versionName":"1.0","sha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","nativeCodes":["arm64-v8a"],"repoFilename":"io.nekohasekai.sfa_100_arm64-v8a_aaaaaaaaaaaa.apk"},
{"source":"sing-box","repository":"SagerNet/sing-box","assetId":102,"packageName":"io.nekohasekai.sfa","versionCode":"100","versionName":"1.0","sha256":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","nativeCodes":["x86_64"],"repoFilename":"io.nekohasekai.sfa_100_x86_64_bbbbbbbbbbbb.apk"},
{"source":"sing-box","repository":"SagerNet/sing-box","assetId":103,"packageName":"io.nekohasekai.sfa","versionCode":"100","versionName":"1.0","sha256":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC","nativeCodes":["arm64-v8a","armeabi-v7a","x86","x86_64"],"repoFilename":"io.nekohasekai.sfa_100_arm64-v8a-armeabi-v7a-x86-x86_64_cccccccccccc.apk"}
]}
JSON
cat > "$tmp/index-v1.json" <<'JSON'
{"packages":{"io.nekohasekai.sfa":[
{"apkName":"io.nekohasekai.sfa_100_arm64-v8a_aaaaaaaaaaaa.apk","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","versionCode":100,"nativecode":["arm64-v8a"]},
{"apkName":"io.nekohasekai.sfa_100_x86_64_bbbbbbbbbbbb.apk","hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","versionCode":100,"nativecode":["x86_64"]},
{"apkName":"io.nekohasekai.sfa_100_arm64-v8a-armeabi-v7a-x86-x86_64_cccccccccccc.apk","hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","versionCode":100,"nativecode":["arm64-v8a","armeabi-v7a","x86","x86_64"]}
]}}
JSON
python3 - "$tmp/index-v1.json" "$tmp/index-v1.jar" <<'PY'
import sys, zipfile
src, dst = sys.argv[1:]
with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(src, "index-v1.json")
PY
cat > "$tmp/index-v2.json" <<'JSON'
{"packages":{"io.nekohasekai.sfa":{"versions":{
"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"file":{"name":"/io.nekohasekai.sfa_100_arm64-v8a_aaaaaaaaaaaa.apk","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"manifest":{"versionCode":100,"nativecode":["arm64-v8a"]}},
"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb":{"file":{"name":"/io.nekohasekai.sfa_100_x86_64_bbbbbbbbbbbb.apk","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"manifest":{"versionCode":100,"nativecode":["x86_64"]}},
"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc":{"file":{"name":"/io.nekohasekai.sfa_100_arm64-v8a-armeabi-v7a-x86-x86_64_cccccccccccc.apk","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"manifest":{"versionCode":100,"nativecode":["arm64-v8a","armeabi-v7a","x86","x86_64"]}}
}}}}
JSON
python3 "$root/scripts/fdroid_sources.py" verify-index \
  --provenance "$tmp/provenance.json" \
  --index-v1 "$tmp/index-v1.jar" \
  --index-v2 "$tmp/index-v2.json" >/dev/null

python3 - "$tmp/index-v1.json" "$tmp/broken-v1.jar" <<'PY'
import json, sys, zipfile
src, dst = sys.argv[1:]
index=json.load(open(src, encoding='utf-8'))
index['packages']['io.nekohasekai.sfa'][0]['nativecode']=['x86_64']
with zipfile.ZipFile(dst, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('index-v1.json', json.dumps(index))
PY
if python3 "$root/scripts/fdroid_sources.py" verify-index \
  --provenance "$tmp/provenance.json" \
  --index-v1 "$tmp/broken-v1.jar" \
  --index-v2 "$tmp/index-v2.json" >/dev/null 2>&1; then
  echo "index verification unexpectedly accepted wrong index-v1 ABI metadata" >&2
  exit 1
fi

python3 - "$tmp/index-v2.json" "$tmp/broken-v2.json" <<'PY'
import json, sys
index=json.load(open(sys.argv[1], encoding='utf-8'))
index['packages']['io.nekohasekai.sfa']['versions'].pop('cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc')
json.dump(index, open(sys.argv[2], 'w', encoding='utf-8'))
PY
if python3 "$root/scripts/fdroid_sources.py" verify-index \
  --provenance "$tmp/provenance.json" \
  --index-v1 "$tmp/index-v1.jar" \
  --index-v2 "$tmp/broken-v2.json" >/dev/null 2>&1; then
  echo "index verification unexpectedly accepted a missing universal fallback variant" >&2
  exit 1
fi

echo "fdroid index-v1/v2 ABI and universal preservation test passed"
