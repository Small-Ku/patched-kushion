#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
HTMLQ="$root/bin/htmlq/htmlq-x86_64"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Model a release page with the same important shape as Google Photos: multiple
# bundles with different ABI/SDK/DPI breadth plus a standalone APK. Shared stock
# discovery must inventory the whole release and prefer the widest reusable bundle.
resp=$(cat <<'HTML'
<div class="variants">
  <div class="table-row headerFont"><div class="table-cell"><a href="/variant-narrow">7.68</a></div><div class="table-cell">x</div><div class="table-cell">BUNDLE</div><div class="table-cell">arm64-v8a + armeabi-v7a</div><div class="table-cell">Android 10+</div><div class="table-cell">213-640dpi</div></div>
  <div class="table-row headerFont"><div class="table-cell"><a href="/variant-modern">7.68</a></div><div class="table-cell">x</div><div class="table-cell">BUNDLE</div><div class="table-cell">universal</div><div class="table-cell">Android 12L+</div><div class="table-cell">120-640dpi</div></div>
  <div class="table-row headerFont"><div class="table-cell"><a href="/variant-broad">7.68</a></div><div class="table-cell">x</div><div class="table-cell">BUNDLE</div><div class="table-cell">universal</div><div class="table-cell">Android 6.0+</div><div class="table-cell">160-640dpi</div></div>
  <div class="table-row headerFont"><div class="table-cell"><a href="/variant-apk">7.68</a></div><div class="table-cell">x</div><div class="table-cell">APK</div><div class="table-cell">universal</div><div class="table-cell">Android 6.0+</div><div class="table-cell">nodpi</div></div>
</div>
HTML
)

inventory=$(apkmirror_inventory "$resp")
[ "$(jq 'length' <<<"$inventory")" -eq 4 ]
[ "$(jq '[.[] | select(.format == "BUNDLE")] | length' <<<"$inventory")" -eq 3 ]

IFS=$'\t' read -r selected arch sdk dpi < <(
  apkmirror_search_shared "$resp" '' '[{"arch":"arm64-v8a"},{"arch":"arm-v7a"}]'
)
[ "$selected" = "https://www.apkmirror.com/variant-broad" ]
[ "$arch" = universal ]
[ "$sdk" = "Android 6.0+" ]
[ "$dpi" = "160-640dpi" ]

# A configured density still accepts and ranks a range that contains it.
IFS=$'\t' read -r selected _ < <(
  apkmirror_search_shared "$resp" xxhdpi '[{"arch":"arm64-v8a"}]'
)
[ "$selected" = "https://www.apkmirror.com/variant-broad" ]

# Shared-source discovery is breadth-first: release-wide APKMirror BUNDLE planning
# happens before generic store fallbacks, while explicit direct input still wins.
[ "${SHARED_DL_SRCS[*]}" = "direct apkmirror apkpure archive uptodown" ]

# Optional branches omitted by the APKMirror planner still get a tiny source
# artifact so downstream download-artifact calls are deterministic.
python3 - "$tmp/arm64.apk" <<'PY_APK'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as apk:
    apk.writestr('AndroidManifest.xml', b'manifest')
    apk.writestr('lib/arm64-v8a/libfixture.so', b'fixture')
PY_APK
cat > "$tmp/plan.json" <<JSON
{
  "schemaVersion": 1,
  "complete": true,
  "requestedArches": ["arm64-v8a", "x86"],
  "requiredArches": ["arm64-v8a"],
  "artifacts": [{"id":"artifact-1","format":"APK","localFile":"$tmp/arm64.apk"}],
  "branchSources": {"arm64-v8a":"artifact-1"}
}
JSON
check_sig() { return 0; }
materialize_apkmirror_download_plan "$tmp/plan.json" "$tmp/materialized" com.example
jq -e '.validated == true and .arch == "arm64-v8a"' "$tmp/materialized/branches/arm64-v8a/branch.json" >/dev/null
jq -e '.available == false and .optional == true and .arch == "x86"' "$tmp/materialized/branches/x86/branch.json" >/dev/null

# Metadata cannot override the downloaded bytes. A planner that labels a fat
# standalone APK as arm64 must fail closed instead of creating a fake ABI branch.
python3 - "$tmp/fat.apk" <<'PY_APK'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as apk:
    apk.writestr('AndroidManifest.xml', b'manifest')
    apk.writestr('lib/arm64-v8a/libfixture.so', b'arm64')
    apk.writestr('lib/armeabi-v7a/libfixture.so', b'armv7')
PY_APK
cat > "$tmp/fat-plan.json" <<JSON
{
  "schemaVersion": 1,
  "complete": true,
  "requestedArches": ["arm64-v8a"],
  "requiredArches": ["arm64-v8a"],
  "artifacts": [{"id":"fat-1","format":"APK","localFile":"$tmp/fat.apk"}],
  "branchSources": {"arm64-v8a":"fat-1"}
}
JSON
if materialize_apkmirror_download_plan "$tmp/fat-plan.json" "$tmp/fat-materialized" com.example; then
  echo 'fat APKMirror standalone was incorrectly accepted as an arm64 derivation' >&2
  exit 1
fi

echo 'APKMirror release inventory test passed'
