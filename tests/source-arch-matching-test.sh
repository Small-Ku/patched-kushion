#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"

# Multi-ABI strings from stores are capabilities, not exact magic strings.
[ "$(source_arch_score 'arm64-v8a + armeabi-v7a + x86 + x86_64' universal)" -eq 504 ]
[ "$(source_arch_score 'arm64-v8a + armeabi-v7a + x86 + x86_64' arm64-v8a)" -eq 896 ]
[ "$(source_arch_score 'arm64-v8a, armeabi-v7a' arm-v7a)" -eq 898 ]
! source_arch_score 'arm64-v8a' universal >/dev/null
! source_arch_score 'x86_64' x86 >/dev/null
[ "$(source_arch_score universal x86_64)" -eq 800 ]

# Artifact-aware matching is stricter for flattened standalone APKs. A fat APK
# only provides universal; split containers retain per-ABI derivability.
[ "$(source_artifact_arch_score 'arm64-v8a + armeabi-v7a + x86 + x86_64' universal APK)" -eq 904 ]
! source_artifact_arch_score 'arm64-v8a + armeabi-v7a + x86 + x86_64' arm64-v8a APK >/dev/null
[ "$(source_artifact_arch_score 'arm64-v8a + armeabi-v7a + x86 + x86_64' arm64-v8a BUNDLE)" -eq 896 ]
[ "$(source_artifact_arch_score arm64-v8a arm64-v8a APK)" -eq 1000 ]
! source_artifact_arch_score universal arm64-v8a APK >/dev/null

# Split containers win over a standalone APK when both can satisfy an ABI.
[ "$(source_format_score BUNDLE)" -gt "$(source_format_score APK)" ]
[ "$(source_format_score xapk)" -gt "$(source_format_score apk)" ]
[ "$(source_dpi_score '120-640dpi' '')" -eq 0 ]
[ "$(source_dpi_score xxhdpi xxhdpi)" -eq 40 ]
[ "$(source_dpi_score nodpi xxhdpi)" -eq 20 ]
! source_dpi_score mdpi xxhdpi >/dev/null

__ARCHIVE_RESP__=$'com.example-1.0-arm64-v8a.apk\ncom.example-1.0-universal.apkm\ncom.example-1.0-universal.apk'
[ "$(archive_select_artifact 1.0 arm64-v8a)" = com.example-1.0-universal.apkm ]
[ "$(archive_select_artifact 1.0 arm-v7a)" = com.example-1.0-universal.apkm ]
[ "$(archive_select_artifact 1.0 universal)" = com.example-1.0-universal.apkm ]

__ARCHIVE_RESP__=$'com.example-1.0-universal.apk\ncom.example-1.0-arm64-v8a.apk'
[ "$(archive_select_artifact 1.0 arm64-v8a)" = com.example-1.0-arm64-v8a.apk ]
! archive_select_artifact 1.0 arm-v7a >/dev/null

# Root module architecture tags use Magisk's ARCH vocabulary; universal is unrestricted.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for pair in 'arm64-v8a arm64' 'arm-v7a arm' 'x86_64 x64' 'x86 x86'; do
  set -- $pair
  module_config "$tmp" com.example 1.0 "$1"
  grep -qx "MODULE_ARCH=$2" "$tmp/config"
done
module_config "$tmp" com.example 1.0 universal
grep -qx 'MODULE_ARCH=' "$tmp/config"

[ "$(source_arch_coverage_score universal '[{"arch":"arm64-v8a"},{"arch":"arm-v7a"},{"arch":"x86_64"},{"arch":"x86"}]')" -eq 4 ]
[ "$(source_arch_coverage_score 'arm64-v8a + armeabi-v7a' '[{"arch":"arm64-v8a"},{"arch":"arm-v7a"},{"arch":"x86"}]')" -eq 2 ]
[ "$(source_sdk_breadth_score 'Android 6.0+')" -gt "$(source_sdk_breadth_score 'Android 12L+')" ]
[ "$(source_dpi_breadth_score '120-640dpi')" -gt "$(source_dpi_breadth_score '320-640dpi')" ]
[ "$(source_dpi_score '120-640dpi' xxhdpi)" -eq 30 ]
[ "$(source_arch_breadth_score universal)" -gt "$(source_arch_breadth_score 'arm64-v8a + armeabi-v7a')" ]
[ "$(source_arch_breadth_score 'arm64-v8a + armeabi-v7a')" -gt "$(source_arch_breadth_score arm64-v8a)" ]

echo 'source architecture capability matching test passed'
