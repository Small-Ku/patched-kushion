#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/releases.json" <<'JSON'
[
  {
    "tag_name": "v2",
    "name": "Version 2",
    "published_at": "2026-08-07T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 202, "name": "app.apk", "browser_download_url": "https://example/app.apk"}
    ]
  }
]
JSON

cat > "$tmp/self-releases.json" <<'JSON'
[
  {
    "tag_name": "10",
    "name": "Release",
    "published_at": "2026-08-07T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 101, "name": "self.apk", "browser_download_url": "https://example/self.apk"}
    ]
  }
]
JSON

cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "unexpected fake gh invocation: $*" >&2; exit 2; }
shift
case "$1" in
  repos/example/patched-kushion/releases\?*) cat "$FAKE_SELF_RELEASES" ;;
  repos/upstream/app/releases\?*) cat "$FAKE_RELEASES" ;;
  *) echo "unexpected endpoint: $1" >&2; exit 2 ;;
esac
FAKE_GH
chmod +x "$tmp/bin/gh"

cat > "$tmp/sources.toml" <<'TOML'
version = 1

[[source]]
name = "self"
repository = "@self"
allow-unpinned = true

[[source]]
name = "external"
repository = "upstream/app"
asset-patterns = ["*.apk"]
release-limit = 1
[source.package-certificates]
"org.example.app" = ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
TOML

cat > "$tmp/provenance.json" <<'JSON'
{
  "schemaVersion": 2,
  "packages": [
    {
      "source": "self",
      "repository": "example/patched-kushion",
      "assetId": 101
    },
    {
      "source": "external",
      "repository": "upstream/app",
      "assetId": 202
    }
  ]
}
JSON

unchanged=$(PATH="$tmp/bin:$PATH" FAKE_RELEASES="$tmp/releases.json" FAKE_SELF_RELEASES="$tmp/self-releases.json" \
  GITHUB_REPOSITORY=example/patched-kushion \
  python3 "$root/scripts/fdroid_sources.py" check \
    --config "$tmp/sources.toml" --provenance "$tmp/provenance.json")
grep -q '^changed=0$' <<<"$unchanged"

sed 's/"id": 202/"id": 203/' "$tmp/releases.json" > "$tmp/releases-new.json"
changed=$(PATH="$tmp/bin:$PATH" FAKE_RELEASES="$tmp/releases-new.json" FAKE_SELF_RELEASES="$tmp/self-releases.json" \
  GITHUB_REPOSITORY=example/patched-kushion \
  python3 "$root/scripts/fdroid_sources.py" check \
    --config "$tmp/sources.toml" --provenance "$tmp/provenance.json")
grep -q '^changed=1$' <<<"$changed"
grep -q 'asset 203' <<<"$changed"
grep -q 'asset 202' <<<"$changed"


sed 's/"id": 101/"id": 102/' "$tmp/self-releases.json" > "$tmp/self-releases-new.json"
self_changed=$(PATH="$tmp/bin:$PATH" FAKE_RELEASES="$tmp/releases.json" FAKE_SELF_RELEASES="$tmp/self-releases-new.json" \
  GITHUB_REPOSITORY=example/patched-kushion \
  python3 "$root/scripts/fdroid_sources.py" check \
    --config "$tmp/sources.toml" --provenance "$tmp/provenance.json")
grep -q '^changed=1$' <<<"$self_changed"
grep -q 'patched-kushion asset 102' <<<"$self_changed"

missing=$(PATH="$tmp/bin:$PATH" FAKE_RELEASES="$tmp/releases.json" FAKE_SELF_RELEASES="$tmp/self-releases.json" \
  GITHUB_REPOSITORY=example/patched-kushion \
  python3 "$root/scripts/fdroid_sources.py" check \
    --config "$tmp/sources.toml" --provenance "$tmp/missing.json")
grep -q '^changed=1$' <<<"$missing"

echo "fdroid source watch test passed"
