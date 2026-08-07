#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo"

cat > "$tmp/releases-self.json" <<'JSON'
[
  {
    "tag_name": "3",
    "name": "Release 3",
    "published_at": "2026-08-03T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 103, "name": "self-v3.apk", "browser_download_url": "https://example/self-v3.apk"}
    ]
  },
  {
    "tag_name": "2",
    "name": "Release 2",
    "published_at": "2026-08-02T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 102, "name": "self-v2.apk", "browser_download_url": "https://example/self-v2.apk"}
    ]
  },
  {
    "tag_name": "1",
    "name": "Release 1",
    "published_at": "2026-08-01T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 101, "name": "self-v1.apk", "browser_download_url": "https://example/self-v1.apk"}
    ]
  }
]
JSON

cat > "$tmp/releases-external.json" <<'JSON'
[
  {
    "tag_name": "v5",
    "name": "External 5",
    "published_at": "2026-08-05T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"id": 205, "name": "external-arm64.apk", "browser_download_url": "https://example/external-arm64.apk"},
      {"id": 207, "name": "external-armv7.apk", "browser_download_url": "https://example/external-armv7.apk"},
      {"id": 210, "name": "external-universal.apk", "browser_download_url": "https://example/external-universal.apk"},
      {"id": 209, "name": "external-legacy-arm64.apk", "browser_download_url": "https://example/external-legacy-arm64.apk"},
      {"id": 206, "name": "checksums.txt", "browser_download_url": "https://example/checksums.txt"}
    ]
  }
]
JSON

cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

[ "$1" = api ] || { echo "unexpected fake gh invocation: $*" >&2; exit 2; }
shift
if [ "${1-}" = -H ]; then
  shift 2
fi
endpoint=$1
case "$endpoint" in
  repos/*/releases/assets/*)
    if [ -n "${FAKE_DOWNLOAD_LOG-}" ]; then
      printf '%s\n' "$endpoint" >> "$FAKE_DOWNLOAD_LOG"
    fi
    if [ "${FAIL_DOWNLOADS-0}" = 1 ]; then
      echo "download unexpectedly attempted: $endpoint" >&2
      exit 99
    fi
    ;;
esac
case "$endpoint" in
  repos/example/patched-kushion/releases\?*) cat "$FAKE_RELEASES_SELF" ;;
  repos/upstream/app/releases\?*) cat "$FAKE_RELEASES_EXTERNAL" ;;
  repos/example/patched-kushion/releases/assets/103) printf 'self|com.example.self|3|Self 3|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
  repos/example/patched-kushion/releases/assets/102) printf 'self|com.example.self|2|Self 2|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
  repos/example/patched-kushion/releases/assets/101) printf 'self|com.example.self|1|Self 1|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' ;;
  repos/upstream/app/releases/assets/205) printf 'external|org.example.external|5|External 5|BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB|arm64-v8a\n' ;;
  repos/upstream/app/releases/assets/207) printf 'external|org.example.external|5|External 5|BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB|armeabi-v7a\n' ;;
  repos/upstream/app/releases/assets/210) printf 'external|org.example.external|5|External 5|BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB|arm64-v8a,armeabi-v7a,x86,x86_64\n' ;;
  *) echo "unexpected endpoint: $endpoint" >&2; exit 2 ;;
esac
FAKE_GH

cat > "$tmp/bin/aapt" <<'FAKE_AAPT'
#!/usr/bin/env bash
set -euo pipefail
file=${3:?missing APK}
IFS='|' read -r _ package code version cert native < "$file"
printf "package: name='%s' versionCode='%s' versionName='%s'\n" "$package" "$code" "$version"
if [ -n "${native-}" ]; then
  IFS=',' read -r -a codes <<< "$native"
  printf 'native-code:'
  for code in "${codes[@]}"; do printf " '%s'" "$code"; done
  printf '\n'
fi
FAKE_AAPT

cat > "$tmp/bin/apksigner" <<'FAKE_APKSIGNER'
#!/usr/bin/env bash
set -euo pipefail
file=${3:?missing APK}
IFS='|' read -r _ package code version cert < "$file"
printf 'Signer #1 certificate SHA-256 digest: %s\n' "$cert"
FAKE_APKSIGNER
chmod +x "$tmp/bin/gh" "$tmp/bin/aapt" "$tmp/bin/apksigner"

cat > "$tmp/sources.toml" <<'TOML'
version = 1

[[source]]
name = "self"
repository = "@self"
asset-patterns = ["*.apk"]
release-limit = 2
allow-unpinned = true

[[source]]
name = "external"
repository = "upstream/app"
asset-patterns = ["external-*.apk"]
asset-exclude-patterns = ["*-legacy-*"]
release-limit = 1
[source.package-certificates]
"org.example.external" = ["BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"]
[source.asset-native-codes]
"external-arm64.apk" = ["arm64-v8a"]
"external-armv7.apk" = ["armeabi-v7a"]
"external-universal.apk" = ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]
TOML

PATH="$tmp/bin:$PATH" \
GH_TOKEN=test-token \
GITHUB_REPOSITORY=example/patched-kushion \
FAKE_RELEASES_SELF="$tmp/releases-self.json" \
FAKE_RELEASES_EXTERNAL="$tmp/releases-external.json" \
FAKE_DOWNLOAD_LOG="$tmp/downloads.log" \
  python3 "$root/scripts/fdroid_sources.py" sync \
    --config "$tmp/sources.toml" \
    --repo-dir "$tmp/repo" \
    --provenance "$tmp/provenance.json" >/dev/null

mapfile -t apks < <(find "$tmp/repo" -maxdepth 1 -type f -name '*.apk' -printf '%f\n' | sort)
[ "${#apks[@]}" -eq 5 ]
printf '%s\n' "${apks[@]}" | grep -q '^com.example.self_2_'
printf '%s\n' "${apks[@]}" | grep -q '^com.example.self_3_'
printf '%s\n' "${apks[@]}" | grep -q '^org.example.external_5_arm64-v8a_'
printf '%s\n' "${apks[@]}" | grep -q '^org.example.external_5_armeabi-v7a_'
printf '%s\n' "${apks[@]}" | grep -q '^org.example.external_5_arm64-v8a-armeabi-v7a-x86-x86_64_'
! printf '%s\n' "${apks[@]}" | grep -q '_1_'

python3 - "$tmp/provenance.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["schemaVersion"] == 3
assert len(manifest["packages"]) == 5
assert {row["assetId"] for row in manifest["packages"]} == {102, 103, 205, 207, 210}
external = [row for row in manifest["packages"] if row["source"] == "external"]
assert len(external) == 3
assert {tuple(row["nativeCodes"]) for row in external} == {
    ("arm64-v8a",),
    ("armeabi-v7a",),
    ("arm64-v8a", "armeabi-v7a", "x86", "x86_64"),
}
assert all(row["repository"] == "upstream/app" for row in external)
assert all(row["packageName"] == "org.example.external" for row in external)
assert all(row["certificateSha256"] == "B" * 64 for row in external)
PY

test "$(wc -l < "$tmp/downloads.log")" -eq 5

# An unchanged release listing must reuse APKs from the existing fdroid branch.
# Release metadata is still queried, but binary download endpoints must not run.
PATH="$tmp/bin:$PATH" \
GH_TOKEN=test-token \
GITHUB_REPOSITORY=example/patched-kushion \
FAKE_RELEASES_SELF="$tmp/releases-self.json" \
FAKE_RELEASES_EXTERNAL="$tmp/releases-external.json" \
FAKE_DOWNLOAD_LOG="$tmp/downloads.log" \
FAIL_DOWNLOADS=1 \
  python3 "$root/scripts/fdroid_sources.py" sync \
    --config "$tmp/sources.toml" \
    --repo-dir "$tmp/repo" \
    --provenance "$tmp/provenance.json" >/dev/null

test "$(wc -l < "$tmp/downloads.log")" -eq 5

# Replacing a release asset creates a new GitHub asset ID. Even when its name
# is unchanged, the old branch copy must not be accepted as that new asset.
sed 's/"id": 205/"id": 208/' \
  "$tmp/releases-external.json" > "$tmp/releases-external-replaced.json"
before_replacement=$(find "$tmp/repo" -maxdepth 1 -type f -name '*.apk' -print0 | sort -z | xargs -0 sha256sum | sha256sum)
if PATH="$tmp/bin:$PATH" \
  GH_TOKEN=test-token \
  GITHUB_REPOSITORY=example/patched-kushion \
  FAKE_RELEASES_SELF="$tmp/releases-self.json" \
  FAKE_RELEASES_EXTERNAL="$tmp/releases-external-replaced.json" \
  FAKE_DOWNLOAD_LOG="$tmp/replacement-downloads.log" \
  FAIL_DOWNLOADS=1 \
    python3 "$root/scripts/fdroid_sources.py" sync \
      --config "$tmp/sources.toml" \
      --repo-dir "$tmp/repo" \
      --provenance "$tmp/provenance.json" >/dev/null 2>&1; then
  echo "replacement asset unexpectedly reused the previous asset ID" >&2
  exit 1
fi
after_replacement=$(find "$tmp/repo" -maxdepth 1 -type f -name '*.apk' -print0 | sort -z | xargs -0 sha256sum | sha256sum)
[ "$before_replacement" = "$after_replacement" ]
test "$(wc -l < "$tmp/replacement-downloads.log")" -eq 1

# A damaged cached APK is not trusted: only that immutable asset is fetched
# again, while the other four APKs continue to be reused.
damaged=$(find "$tmp/repo" -maxdepth 1 -type f -name 'org.example.external_5_arm64-v8a_*.apk')
test -n "$damaged"
printf 'damaged cache entry\n' > "$damaged"
PATH="$tmp/bin:$PATH" \
GH_TOKEN=test-token \
GITHUB_REPOSITORY=example/patched-kushion \
FAKE_RELEASES_SELF="$tmp/releases-self.json" \
FAKE_RELEASES_EXTERNAL="$tmp/releases-external.json" \
FAKE_DOWNLOAD_LOG="$tmp/downloads.log" \
  python3 "$root/scripts/fdroid_sources.py" sync \
    --config "$tmp/sources.toml" \
    --repo-dir "$tmp/repo" \
    --provenance "$tmp/provenance.json" >/dev/null

test "$(wc -l < "$tmp/downloads.log")" -eq 6
grep -q '^external|' "$damaged"

cp "$tmp/sources.toml" "$tmp/bad-sources.toml"
sed -i 's/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/' "$tmp/bad-sources.toml"
before=$(find "$tmp/repo" -maxdepth 1 -type f -name '*.apk' -print0 | sort -z | xargs -0 sha256sum | sha256sum)
if PATH="$tmp/bin:$PATH" \
  GH_TOKEN=test-token \
  GITHUB_REPOSITORY=example/patched-kushion \
  FAKE_RELEASES_SELF="$tmp/releases-self.json" \
  FAKE_RELEASES_EXTERNAL="$tmp/releases-external.json" \
  FAKE_DOWNLOAD_LOG="$tmp/downloads.log" \
  FAIL_DOWNLOADS=1 \
    python3 "$root/scripts/fdroid_sources.py" sync \
      --config "$tmp/bad-sources.toml" \
      --repo-dir "$tmp/repo" \
      --provenance "$tmp/provenance.json" >/dev/null 2>&1; then
  echo "certificate mismatch unexpectedly succeeded" >&2
  exit 1
fi
after=$(find "$tmp/repo" -maxdepth 1 -type f -name '*.apk' -print0 | sort -z | xargs -0 sha256sum | sha256sum)
[ "$before" = "$after" ]
test "$(wc -l < "$tmp/downloads.log")" -eq 6

# Asset filenames are not trusted as ABI declarations.
cp "$tmp/sources.toml" "$tmp/bad-abi-sources.toml"
sed -i 's/"external-arm64.apk" = \["arm64-v8a"\]/"external-arm64.apk" = ["x86_64"]/' "$tmp/bad-abi-sources.toml"
if PATH="$tmp/bin:$PATH" \
  GH_TOKEN=test-token \
  GITHUB_REPOSITORY=example/patched-kushion \
  FAKE_RELEASES_SELF="$tmp/releases-self.json" \
  FAKE_RELEASES_EXTERNAL="$tmp/releases-external.json" \
  FAKE_DOWNLOAD_LOG="$tmp/downloads.log" \
  FAIL_DOWNLOADS=1 \
    python3 "$root/scripts/fdroid_sources.py" sync \
      --config "$tmp/bad-abi-sources.toml" \
      --repo-dir "$tmp/repo" \
      --provenance "$tmp/provenance.json" >/dev/null 2>&1; then
  echo "native-code mismatch unexpectedly succeeded" >&2
  exit 1
fi

echo "fdroid multi-source sync test passed"
