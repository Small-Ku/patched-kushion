#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/releases.json" <<'JSON'
[
  {
    "tag_name": "v9",
    "name": "Version 9",
    "published_at": "2026-08-06T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 901, "name": "app-universal.apk", "browser_download_url": "https://example/app.apk"},
      {"id": 902, "name": "app-arm64.apk", "browser_download_url": "https://example/app-arm64.apk"}
    ]
  }
]
JSON

cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
shift
if [ "${1-}" = -H ]; then shift 2; fi
case "$1" in
  repos/upstream/new-app/releases\?*) cat "$FAKE_RELEASES" ;;
  repos/upstream/new-app/releases/assets/901) printf 'apk|com.example.new|9|New 9|CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\n' ;;
  repos/upstream/new-app/releases/assets/902) printf 'apk|com.example.new|9|New 9|CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\n' ;;
  *) echo "unexpected endpoint: $1" >&2; exit 2 ;;
esac
FAKE_GH

cat > "$tmp/bin/aapt" <<'FAKE_AAPT'
#!/usr/bin/env bash
set -euo pipefail
IFS='|' read -r _ package code version cert < "${3:?}"
printf "package: name='%s' versionCode='%s' versionName='%s'\n" "$package" "$code" "$version"
FAKE_AAPT

cat > "$tmp/bin/apksigner" <<'FAKE_APKSIGNER'
#!/usr/bin/env bash
set -euo pipefail
IFS='|' read -r _ package code version cert < "${3:?}"
printf 'Signer #1 certificate SHA-256 digest: %s\n' "$cert"
FAKE_APKSIGNER
chmod +x "$tmp/bin/gh" "$tmp/bin/aapt" "$tmp/bin/apksigner"

cat > "$tmp/sources.toml" <<'TOML'
config-version = 1
[fdroid]
include-built-releases = false

[apps.existing]
package-name = "de.kwoo.shion.existing"
upstream-package = "com.example.existing"
[apps.existing.build]
build-mode = "apk"
TOML

PATH="$tmp/bin:$PATH" \
GH_TOKEN=test-token \
FAKE_RELEASES="$tmp/releases.json" \
  python3 "$root/scripts/fdroid_sources.py" add upstream/new-app \
    --config "$tmp/sources.toml" \
    --name new-app \
    --pattern 'app-universal.apk' \
    --release-limit 4 >/dev/null

python3 - "$tmp/sources.toml" <<'PY'
import pathlib
import sys
import tomllib

config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
app = config["apps"]["new-app"]
assert app["package-name"] == "com.example.new"
release = app["release"]
assert release["repository"] == "upstream/new-app"
assert release["asset-patterns"] == ["app-universal.apk"]
assert release["release-limit"] == 4
assert release["certificates"] == ["C" * 64]
PY

echo "fdroid add-release-app test passed"
