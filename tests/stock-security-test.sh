#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
# shellcheck disable=SC1091
source "$root/tests/testlib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; BIN_DIR="$tmp/bin"; mkdir -p "$TEMP_DIR" "$BIN_DIR"

python3 - "$tmp/a.apk" "$tmp/b.apk" "$tmp/injected.apk" <<'PY'
import sys, zipfile
for path, injected in [(sys.argv[1], False), (sys.argv[2], False), (sys.argv[3], True)]:
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('AndroidManifest.xml', b'manifest')
        z.writestr('classes.dex', b'dex-code')
        z.writestr('lib/arm64-v8a/libx.so', b'native')
        if injected:
            z.writestr('classes3.dex', b'DataCollector https://38.190.225.166/api/collect_batch')
PY

cat > "$tmp/aapt2" <<'AAPT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = dump ]
case "$2" in
  badging)
    cat <<'EOF'
package: name='com.example.app' versionCode='123' versionName='2.3.4'
sdkVersion:'24'
targetSdkVersion:'35'
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.CAMERA'
EOF
    ;;
  xmltree)
    cat <<'EOF'
E: manifest (line=1)
  E: application (line=2)
    E: activity (line=3)
      A: android:name(0x01010003)="com.example.Main" (Raw: "com.example.Main")
      A: android:exported(0x01010010)=(type 0x12)0xffffffff
    E: service (line=4)
      A: android:name(0x01010003)="com.example.Sync" (Raw: "com.example.Sync")
      A: android:exported(0x01010010)=(type 0x12)0x0
EOF
    ;;
  *) exit 2 ;;
esac
AAPT
chmod +x "$tmp/aapt2"
AAPT2="$tmp/aapt2"

python3 scripts/stock_fingerprint.py --apk "$tmp/a.apk" --aapt2 "$AAPT2" --output "$tmp/a.json" --indicator 38.190.225.166
python3 scripts/stock_fingerprint.py --apk "$tmp/b.apk" --aapt2 "$AAPT2" --output "$tmp/b.json" --indicator 38.190.225.166
python3 scripts/stock_fingerprint.py --apk "$tmp/injected.apk" --aapt2 "$AAPT2" --output "$tmp/injected.json" --indicator 38.190.225.166
jq -e '.packageName=="com.example.app" and .versionName=="2.3.4" and .permissions==["android.permission.CAMERA","android.permission.INTERNET"] and (.components|length)==2' "$tmp/a.json" >/dev/null
[ "$(jq -r .comparisonSha256 "$tmp/a.json")" = "$(jq -r .comparisonSha256 "$tmp/b.json")" ]
[ "$(jq -r .comparisonSha256 "$tmp/a.json")" != "$(jq -r .comparisonSha256 "$tmp/injected.json")" ]
jq -e '.indicatorMatches == [{"entry":"classes3.dex","indicator":"38.190.225.166"}]' "$tmp/injected.json" >/dev/null

__TOML__=$(jq -n --arg sha "$(sha256sum "$tmp/a.apk" | awk '{print $1}')" '{"stock-security":{"deny-sha256":[$sha],"deny-indicators":[]}}')
expect_failure_matching \
  'quarantine a configured known-bad stock hash' 3 \
  'Quarantining known-bad stock artifact' \
  verify_stock_security "$tmp/a.apk" com.example.app 2.3.4 direct "$tmp/blocked.json"

__TOML__='{"stock-security":{"deny-sha256":[],"deny-indicators":["38.190.225.166"]}}'
expect_failure_matching \
  'quarantine a stock artifact containing a configured security indicator' 3 \
  'configured security indicator matched' \
  verify_stock_security "$tmp/injected.apk" com.example.app 2.3.4 apkpure "$tmp/ioc.json"

__TOML__='{"stock-security":{"deny-sha256":[],"deny-indicators":[]}}'
verify_stock_security "$tmp/a.apk" com.example.app 2.3.4 apkpure "$tmp/safe.json"
jq -e '.securityValidated==true and .source=="apkpure" and .trustClass=="third-party-store" and .sourceProvenanceFamily=="apkpure" and .sourceProvenanceDomain=="apkpure.com" and (.comparisonSha256|length)==64' "$tmp/safe.json" >/dev/null

echo 'stock security fingerprint test passed'
