#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
output=${1:-temp/kushion-patches}
mkdir -p "$output"
# This MPP contains an Android extension. AGP needs JDK 21 and a real,
# versioned Android SDK; the extension-free fallback remains available.
output=$(cd "$output" && pwd)
if [ -n "${CONDA_PREFIX:-}" ] && [ -x "$CONDA_PREFIX/bin/java" ]; then
  export JAVA_HOME="$CONDA_PREFIX"
fi
if find kushion-patches/extensions -mindepth 2 -maxdepth 2 -name build.gradle.kts -print -quit 2>/dev/null | grep -q .; then
  if [ -n "${JAVA_HOME_21_X64:-}" ] && [ -x "$JAVA_HOME_21_X64/bin/java" ]; then
    export JAVA_HOME="$JAVA_HOME_21_X64"
  elif command -v mise >/dev/null 2>&1; then
    java21=$(mise where java@21 2>/dev/null || true)
    if [ -n "$java21" ] && [ -x "$java21/bin/java" ]; then
      export JAVA_HOME="$java21"
    fi
  fi
  [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ] || {
    echo >&2 "Kushion Android extension requires a JDK 21 installation"
    exit 1
  }
  "$JAVA_HOME/bin/java" -version 2>&1 | grep -Eq 'version "21[.]' || {
    echo >&2 "Kushion Android extension requires JDK 21 for Gradle"
    exit 1
  }
  export PATH="$JAVA_HOME/bin:$PATH"
  sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
  [ -n "$sdk_root" ] && [ -f "$sdk_root/platforms/android-36/android.jar" ] || {
    echo >&2 "Kushion Android extension requires the Android 36 SDK platform"
    exit 1
  }
else
  export ANDROID_HOME="$output/no-platform-sdk" ANDROID_SDK_ROOT="$output/no-platform-sdk"
fi
bash kushion-patches/gradlew -p kushion-patches --no-daemon test buildAndroid
mapfile -t bundles < <(find kushion-patches/patches/build/libs -maxdepth 1 -name '*.mpp' -type f)
[ "${#bundles[@]}" -eq 1 ] || { echo >&2 'Expected exactly one Kushion Patches MPP'; exit 1; }
cp "${bundles[0]}" "$output/kushion-patches.mpp"
python3 scripts/kushion_patches.py write --root "$output"
