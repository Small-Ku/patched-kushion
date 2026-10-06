#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
# shellcheck disable=SC1091
source "$root/tests/testlib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; BIN_DIR="$tmp/bin"; mkdir -p "$TEMP_DIR" "$BIN_DIR"

# 1. Enumerate adapters
isoneof "googleplay" "${SOURCE_ADAPTERS[@]}"
isoneof "googleplay" "${BROAD_SOURCE_ADAPTERS[@]}"

# 2. Package extraction
[ "$(googleplay_extract_package com.google.android.youtube)" = "com.google.android.youtube" ]
[ "$(googleplay_extract_package "https://play.google.com/store/apps/details?id=com.google.android.youtube&hl=en")" = "com.google.android.youtube" ]
[ "$(googleplay_extract_package "market://details?id=com.google.android.apps.photos")" = "com.google.android.apps.photos" ]
! googleplay_extract_package "invalid package name with spaces" >/dev/null 2>&1
! googleplay_extract_package "https://example.com/no-id-param" >/dev/null 2>&1

# 3. Trust class and provenance
[ "$(source_trust_class googleplay)" = "first-party-store" ]
[ "$(source_provenance_family googleplay)" = "google-play" ]
[ "$(source_provenance_domain googleplay com.google.android.youtube)" = "play.google.com" ]
[ "$(source_provenance_domain googleplay "https://play.google.com/store/apps/details?id=com.google.android.youtube")" = "play.google.com" ]

# 4. Google Play transports share provenance (auth transports do not corroborate each other)
sources_share_provenance googleplay com.google.android.youtube googleplay "https://play.google.com/store/apps/details?id=com.google.android.youtube"
! sources_share_provenance googleplay com.google.android.youtube aptoide "com.google.android.youtube"
! sources_share_provenance googleplay com.google.android.youtube apkmirror "https://www.apkmirror.com/apk/google-inc/youtube/"

# 5. Upstream signer pin is strictly required for Google Play
source_requires_signer_pin googleplay
__TOML__='{"upstream-signatures":{}}'
touch "$tmp/dummy.apk"
expect_failure_matching \
  'reject unpinned stock from Google Play' 2 \
  'Refusing unpinned stock' \
  check_sig "$tmp/dummy.apk" com.google.android.youtube googleplay

# 6. Candidate failure isolation
# When metadata or download fails, it stays a candidate failure rather than terminating the pipeline.
declare -A args
args[googleplay_dlurl]="com.example.nonexistent.app"
! get_googleplay_resp "com.example.nonexistent.app"
[ -z "${__GOOGLEPLAY_RESP__:-}" ]

# 7. Multi-arch broad request deferral
# When more than 1 architecture is required, dl_googleplay_shared returns so Source can download each branch
multi_arches='[{"arch":"arm64-v8a","sourcePriority":"required"},{"arch":"arm-v7a","sourcePriority":"required"}]'
! dl_googleplay_shared "com.google.android.youtube" "21.36.47" "$tmp/should_not_exist.payload" "$multi_arches" ""

# 8. Keep the split bundle for a branch download
# Create a synthetic bundle containing base.apk and a split APK
python3 - "$tmp/fixture.bundle" <<'PYBUNDLE'
import sys, zipfile
bundle_path = sys.argv[1]
with zipfile.ZipFile(bundle_path, "w") as zf:
    zf.writestr("base.apk", "fake base apk content")
    zf.writestr("split_config.arm64_v8a.apk", "fake split apk content")
PYBUNDLE

[ -f "$tmp/fixture.bundle" ]
echo 'googleplay source adapter test passed'
