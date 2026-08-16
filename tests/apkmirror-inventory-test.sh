#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
HTMLQ="$root/bin/htmlq/htmlq-x86_64"

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

# Shared-source discovery keeps fragile APKMirror HTML scraping as a late fallback.
[ "${SHARED_DL_SRCS[*]}" = "direct apkpure uptodown archive apkmirror" ]

echo 'APKMirror release inventory test passed'
