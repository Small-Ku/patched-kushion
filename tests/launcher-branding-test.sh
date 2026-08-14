#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/decoded/res/mipmap-anydpi-v26" "$tmp/overlay/res/mipmap-anydpi-v26"
cat > "$tmp/decoded/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="example.app">
  <application android:label="Old">
    <activity android:name=".Main" android:label="Old Activity">
      <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
    </activity>
    <activity android:name=".Other" android:label="Keep"/>
  </application>
</manifest>
XML
printf '<adaptive-icon />\n' > "$tmp/overlay/res/mipmap-anydpi-v26/ic_launcher.xml"
python3 "$root/scripts/launcher_branding.py" --decoded "$tmp/decoded" --name 'Kou Example' --icon-overlay "$tmp/overlay" --report "$tmp/report.json"
python3 - "$tmp/decoded/AndroidManifest.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
A='{http://schemas.android.com/apk/res/android}'
r=ET.parse(sys.argv[1]).getroot(); app=r.find('application')
assert app.get(A+'label') == 'Kou Example'
acts=app.findall('activity')
assert acts[0].get(A+'label') == 'Kou Example'
assert acts[1].get(A+'label') == 'Keep'
PY
[ -f "$tmp/decoded/res/mipmap-anydpi-v26/ic_launcher.xml" ]
[ "$(jq -r .launcherComponents "$tmp/report.json")" -eq 1 ]
mkdir -p "$tmp/bad"; printf x > "$tmp/escape.txt"
python3 - <<PY
import zipfile
with zipfile.ZipFile('$tmp/bad.zip','w') as z: z.writestr('../escape.txt','x')
PY
if python3 "$root/scripts/launcher_branding.py" --decoded "$tmp/decoded" --icon-overlay "$tmp/bad.zip" >/dev/null 2>&1; then
  echo 'unsafe overlay unexpectedly accepted' >&2; exit 1
fi
echo 'launcher branding test passed'
