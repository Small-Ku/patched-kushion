#!/usr/bin/env bash
set -euo pipefail

version=${1:-${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}}
sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
if [ -z "$sdk_root" ]; then
  echo >&2 "ANDROID_SDK_ROOT or ANDROID_HOME must point to an Android SDK"
  exit 1
fi

build_tools="$sdk_root/build-tools/$version"
required=(aapt aapt2 apksigner zipalign)
missing=false
for tool in "${required[@]}"; do
  if [ ! -x "$build_tools/$tool" ]; then
    missing=true
    break
  fi
done

if [ "$missing" = true ]; then
  sdkmanager=${SDKMANAGER:-}
  if [ -z "$sdkmanager" ] || [ ! -x "$sdkmanager" ]; then
    sdkmanager=$(command -v sdkmanager 2>/dev/null || true)
  fi
  if [ -z "$sdkmanager" ]; then
    sdkmanager=$(find "$sdk_root/cmdline-tools" -type f -path '*/bin/sdkmanager' -perm -u+x -print 2>/dev/null | sort -V | tail -1)
  fi
  if [ -z "$sdkmanager" ] || [ ! -x "$sdkmanager" ]; then
    echo >&2 "Android Build Tools $version are missing and sdkmanager was not found"
    exit 1
  fi
  "$sdkmanager" "build-tools;$version"
fi

for tool in "${required[@]}"; do
  if [ ! -x "$build_tools/$tool" ]; then
    echo >&2 "Android Build Tools $version are incomplete: $build_tools/$tool is missing"
    exit 1
  fi
done

printf 'Using Android Build Tools %s from %s\n' "$version" "$build_tools"
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    printf 'ANDROID_BUILD_TOOLS_DIR=%s\n' "$build_tools"
    printf 'ZIPALIGN=%s\n' "$build_tools/zipalign"
    printf 'APKSIGNER=%s\n' "$build_tools/apksigner"
    printf 'AAPT2=%s\n' "$build_tools/aapt2"
  } >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$build_tools" >> "$GITHUB_PATH"
fi
