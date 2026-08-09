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

# Root module architecture tags use Magisk's ARCH vocabulary; universal is unrestricted.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for pair in 'arm64-v8a arm64' 'arm-v7a arm' 'x86_64 x64' 'x86 x86'; do
  set -- $pair
  module_config "$tmp" com.example 1.0 "$1"
  grep -qx "MODULE_ARCH=$2" "$tmp/config"
done
module_config "$tmp" com.example 1.0 universal
grep -qx 'MODULE_ARCH=' "$tmp/config"

echo 'source architecture capability matching test passed'
