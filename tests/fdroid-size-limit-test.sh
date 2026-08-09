#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 2
case "${@: -1}" in
  repos/example/patched-kushion/releases\?per_page=100\&page=1)
    cat <<'JSON'
[
  {"tag_name":"10","draft":false,"prerelease":false,"published_at":"2026-08-10T00:00:00Z","assets":[
    {"id":101,"name":"kouphotos-v10-arm64-v8a.apk","size":90439680,"browser_download_url":"https://example/small.apk"},
    {"id":102,"name":"kouphotos-v10-universal.apk","size":180879360,"browser_download_url":"https://example/large.apk"}
  ]}
]
JSON
    ;;
  *) echo "unexpected endpoint: ${@: -1}" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"
cat > "$tmp/sources.toml" <<'TOML'
version = 1
[[source]]
name = "patched-kushion"
repository = "@self"
asset-patterns = ["*.apk"]
max-asset-size = 104857600
release-limit = 10
include-prereleases = false
allow-unpinned = true
TOML
cat > "$tmp/provenance.json" <<'JSON'
{"schemaVersion":3,"packages":[{"source":"patched-kushion","repository":"example/patched-kushion","assetId":101}]}
JSON
PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=example/patched-kushion \
  python3 "$root/scripts/fdroid_sources.py" check --config "$tmp/sources.toml" --provenance "$tmp/provenance.json" \
  >"$tmp/out" 2>"$tmp/err"
grep -qx 'changed=0' "$tmp/out"
grep -q 'kouphotos-v10-universal.apk: 180879360 bytes exceeds max-asset-size=104857600' "$tmp/err"
echo 'F-Droid release asset size limit test passed'
