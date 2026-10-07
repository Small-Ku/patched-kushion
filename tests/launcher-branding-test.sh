#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/decoded/res"

cat > "$tmp/decoded/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="example.app">
  <application android:label="Old" android:icon="@mipmap/upstream" android:roundIcon="@mipmap/upstream_round">
    <activity android:name=".Main" android:label="Old Activity" android:icon="@drawable/upstream_activity">
      <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
    </activity>
    <activity-alias android:name=".Alias" android:targetActivity=".Main" android:label="Old Alias" android:icon="@drawable/upstream_alias">
      <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
    </activity-alias>
    <activity android:name=".Other" android:label="Keep"/>
  </application>
</manifest>
XML

python3 "$root/scripts/launcher_branding.py" \
  --decoded "$tmp/decoded" \
  --name KnitTube \
  --icon-overlay "$root/branding/knit/tube" \
  --icon-resource @mipmap/knit_launcher \
  --report "$tmp/report.json"

python3 - "$tmp/decoded/AndroidManifest.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
A='{http://schemas.android.com/apk/res/android}'
r=ET.parse(sys.argv[1]).getroot(); app=r.find('application')
assert app.get(A+'label') == 'KnitTube'
assert app.get(A+'icon') == '@mipmap/knit_launcher'
assert app.get(A+'roundIcon') == '@mipmap/knit_launcher'
launchers = []
other = None
for tag in ('activity', 'activity-alias'):
    for node in app.findall(tag):
        if node.get(A+'name') == '.Other':
            other = node
        if node.get(A+'name') in {'.Main', '.Alias'}:
            launchers.append(node)
assert len(launchers) == 2
assert all(node.get(A+'label') == 'KnitTube' for node in launchers)
assert all(node.get(A+'icon') == '@mipmap/knit_launcher' for node in launchers)
assert other is not None and other.get(A+'label') == 'Keep' and other.get(A+'icon') is None
PY

test -f "$tmp/decoded/res/mipmap/knit_launcher.xml"
test -f "$tmp/decoded/res/mipmap-anydpi-v26/knit_launcher.xml"
test -f "$tmp/decoded/res/mipmap-anydpi-v33/knit_launcher.xml"
test -f "$tmp/decoded/res/drawable/knit_launcher_monochrome.xml"
grep -Fq '<monochrome android:drawable="@drawable/knit_launcher_monochrome"' \
  "$tmp/decoded/res/mipmap-anydpi-v33/knit_launcher.xml"
test "$(jq -r .launcherComponents "$tmp/report.json")" -eq 2
test "$(jq -r .iconComponents "$tmp/report.json")" -eq 2
test "$(jq -r .iconResource "$tmp/report.json")" = '@mipmap/knit_launcher'
test "$(jq -r .overlayFiles "$tmp/report.json")" -eq 7

python3 - "$root/config.toml" "$root/branding/knit" <<'PY'
import sys, tomllib, xml.etree.ElementTree as ET
from pathlib import Path

config = tomllib.loads(Path(sys.argv[1]).read_text())
branding = Path(sys.argv[2])
expected = {
    'KouTube': ('KnitTube', 'tube'),
    'KouMusik': ('KnitMusic', 'music'),
    'KouPhotos': ('KnitPhotos', 'photos'),
    'KouInstagram': ('Knitstagram', 'instagram'),
    'KouMessenger': ('KnitMessenger', 'messenger'),
}
for target, (name, directory) in expected.items():
    app = config['apps'][target]
    build = app['build']
    assert app['display-name'] == name
    assert build['launcher-name'] == name
    assert build['launcher-icon-overlay'] == f'branding/knit/{directory}'
    assert build['launcher-icon-resource'] == '@mipmap/knit_launcher'
    root = branding / directory / 'res'
    required = [
        root / 'mipmap/knit_launcher.xml',
        root / 'mipmap-anydpi-v26/knit_launcher.xml',
        root / 'mipmap-anydpi-v33/knit_launcher.xml',
        root / 'drawable/knit_launcher_background.xml',
        root / 'drawable/knit_launcher_legacy_background.xml',
        root / 'drawable/knit_launcher_foreground.xml',
        root / 'drawable/knit_launcher_monochrome.xml',
    ]
    assert all(path.is_file() for path in required)
    for path in required:
        ET.parse(path)
    adaptive33 = ET.parse(root / 'mipmap-anydpi-v33/knit_launcher.xml').getroot()
    assert adaptive33.tag == 'adaptive-icon'
    assert adaptive33.find('monochrome') is not None
PY

mkdir -p "$tmp/bad"
python3 - "$tmp/bad.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('../escape.txt', 'x')
PY
if python3 "$root/scripts/launcher_branding.py" \
  --decoded "$tmp/decoded" --icon-overlay "$tmp/bad.zip" >/dev/null 2>&1; then
  echo 'unsafe overlay unexpectedly accepted' >&2
  exit 1
fi

if python3 "$root/scripts/launcher_branding.py" \
  --decoded "$tmp/decoded" --icon-resource @mipmap/missing >/dev/null 2>&1; then
  echo 'missing launcher icon resource unexpectedly accepted' >&2
  exit 1
fi

mkdir -p "$tmp/no-base/res/mipmap-anydpi-v26"
printf '<adaptive-icon />\n' > "$tmp/no-base/res/mipmap-anydpi-v26/qualified_only.xml"
cp "$tmp/decoded/AndroidManifest.xml" "$tmp/no-base/AndroidManifest.xml"
if python3 "$root/scripts/launcher_branding.py" \
  --decoded "$tmp/no-base" --icon-resource @mipmap/qualified_only >/dev/null 2>&1; then
  echo 'qualified-only launcher icon resource unexpectedly accepted' >&2
  exit 1
fi

echo 'launcher branding test passed'
