#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/metadata"

cat > "$tmp/releases.json" <<'JSON'
[
  {
    "tag_name": "v2-beta.2",
    "name": "Version 2 beta 2",
    "published_at": "2026-08-07T00:00:00Z",
    "draft": false,
    "prerelease": true,
    "assets": [
      {"id": 302, "name": "app-universal.apk", "browser_download_url": "https://example/beta.apk"}
    ]
  },
  {
    "tag_name": "v2-beta.1",
    "name": "Version 2 beta 1",
    "published_at": "2026-08-06T00:00:00Z",
    "draft": false,
    "prerelease": true,
    "assets": [
      {"id": 301, "name": "app-universal.apk", "browser_download_url": "https://example/beta1.apk"}
    ]
  },
  {
    "tag_name": "v1",
    "name": "Version 1",
    "published_at": "2026-08-01T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 201, "name": "app-universal.apk", "browser_download_url": "https://example/stable.apk"}
    ]
  }
]
JSON

cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 2
shift
if [ "${1-}" = -H ]; then shift 2; fi
case "$1" in
  repos/upstream/app/releases\?*) cat "$FAKE_RELEASES" ;;
  repos/upstream/app/releases/assets/302) printf 'beta|org.example.app|200|2.0-beta.2|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
  repos/upstream/app/releases/assets/301) printf 'beta|org.example.app|199|2.0-beta.1|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
  repos/upstream/app/releases/assets/201) printf 'stable|org.example.app|100|1.0|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
  *) echo "unexpected endpoint: $1" >&2; exit 2 ;;
esac
FAKE_GH
cat > "$tmp/bin/aapt" <<'FAKE_AAPT'
#!/usr/bin/env bash
set -euo pipefail
file=${3:?missing APK}
IFS='|' read -r _ package code version cert native < "$file"
printf "package: name='%s' versionCode='%s' versionName='%s'\n" "$package" "$code" "$version"
FAKE_AAPT
cat > "$tmp/bin/apksigner" <<'FAKE_APKSIGNER'
#!/usr/bin/env bash
set -euo pipefail
file=${3:?missing APK}
IFS='|' read -r _ package code version cert native < "$file"
printf 'Signer #1 certificate SHA-256 digest: %s\n' "$cert"
FAKE_APKSIGNER
chmod +x "$tmp/bin/gh" "$tmp/bin/aapt" "$tmp/bin/apksigner"

cat > "$tmp/sources.toml" <<'TOML'
version = 1
[[source]]
name = "external"
repository = "upstream/app"
asset-patterns = ["app-universal.apk"]
release-limit = 1
include-prereleases = true
[source.package-certificates]
"org.example.app" = ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
TOML

PATH="$tmp/bin:$PATH" FAKE_RELEASES="$tmp/releases.json" \
  python3 "$root/scripts/fdroid_sources.py" sync \
    --config "$tmp/sources.toml" --repo-dir "$tmp/repo" \
    --provenance "$tmp/provenance.json" >/dev/null

python3 - "$tmp/provenance.json" <<'PY'
import json, sys
m=json.load(open(sys.argv[1], encoding='utf-8'))
assert m['schemaVersion'] == 3
rows=m['packages']
# release-limit=1 keeps the newest prerelease plus the newest stable anchor.
assert {r['assetId'] for r in rows} == {302, 201}
assert {r['assetId']: r['prerelease'] for r in rows} == {302: True, 201: False}
PY

PATH="$tmp/bin:$PATH" python3 "$root/scripts/fdroid_sources.py" metadata \
  --config "$tmp/sources.toml" --provenance "$tmp/provenance.json" \
  --metadata-dir "$tmp/metadata" >/dev/null

grep -q '^CurrentVersion: "1.0"$' "$tmp/metadata/org.example.app.yml"
grep -q '^CurrentVersionCode: 100$' "$tmp/metadata/org.example.app.yml"

echo "fdroid prerelease channel test passed"
