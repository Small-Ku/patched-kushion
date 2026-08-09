#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 2
case "${@: -1}" in
  repos/SagerNet/sing-box/releases\?per_page=100\&page=1)
    cat <<'JSON'
[
  {"tag_name":"v1.13.0","draft":false,"prerelease":false,"published_at":"2026-08-10T00:00:00Z","assets":[
    {"id":101,"name":"SFA-1.13.0-arm64-v8a.apk","size":90439680,"browser_download_url":"https://example/small.apk"},
    {"id":102,"name":"SFA-1.13.0-universal.apk","size":122179584,"browser_download_url":"https://example/large.apk"}
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
max-repo-asset-size = 104857600

[[source]]
name = "sing-box"
repository = "SagerNet/sing-box"
asset-patterns = ["SFA-*.apk"]
release-limit = 5
include-prereleases = true
TOML
cat > "$tmp/provenance.json" <<'JSON'
{"schemaVersion":3,"packages":[{"source":"sing-box","repository":"SagerNet/sing-box","assetId":101}]}
JSON
PATH="$tmp/bin:$PATH" \
  python3 "$root/scripts/fdroid_sources.py" check --config "$tmp/sources.toml" --provenance "$tmp/provenance.json" \
  >"$tmp/out" 2>"$tmp/err"
grep -qx 'changed=0' "$tmp/out"
grep -q 'SFA-1.13.0-universal.apk: 122179584 bytes exceeds max-repo-asset-size=104857600' "$tmp/err"

truncate -s 104857600 "$tmp/repo/at-limit.apk"
python3 "$root/scripts/fdroid_sources.py" verify-repo-size \
  --config "$tmp/sources.toml" --repo-dir "$tmp/repo" >/dev/null
truncate -s 104857601 "$tmp/repo/too-large.apk"
if python3 "$root/scripts/fdroid_sources.py" verify-repo-size \
  --config "$tmp/sources.toml" --repo-dir "$tmp/repo" >"$tmp/verify-out" 2>"$tmp/verify-err"; then
  echo >&2 'verify-repo-size unexpectedly accepted an oversized APK'
  exit 1
fi
grep -q 'too-large.apk (104857601 bytes)' "$tmp/verify-err"

rm "$tmp/repo/too-large.apk"
mkdir -p "$tmp/publish/fdroid/repo"
cp "$tmp/repo/at-limit.apk" "$tmp/publish/fdroid/repo/at-limit.apk"
truncate -s 104857601 "$tmp/publish/fdroid/index-v2.json"
if python3 "$root/scripts/fdroid_sources.py" verify-publish-size \
  --config "$tmp/sources.toml" --root "$tmp/publish" >"$tmp/tree-out" 2>"$tmp/tree-err"; then
  echo >&2 'verify-publish-size unexpectedly accepted an oversized non-APK blob'
  exit 1
fi
grep -q 'fdroid/index-v2.json (104857601 bytes)' "$tmp/tree-err"

echo 'F-Droid global repository size limit test passed'
