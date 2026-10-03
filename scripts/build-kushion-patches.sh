#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
output=${1:-temp/kushion-patches}
mkdir -p "$output"
# This project has no Android extensions. The plugin otherwise probes the host's
# newest android.jar, silently changing D8 output across runners with the same source.
output=$(cd "$output" && pwd)
export ANDROID_HOME="$output/no-platform-sdk" ANDROID_SDK_ROOT="$output/no-platform-sdk"
if [ -n "${CONDA_PREFIX:-}" ] && [ -x "$CONDA_PREFIX/bin/java" ]; then
  export JAVA_HOME="$CONDA_PREFIX"
fi
bash kushion-patches/gradlew -p kushion-patches --no-daemon test buildAndroid
mapfile -t bundles < <(find kushion-patches/patches/build/libs -maxdepth 1 -name '*.mpp' -type f)
[ "${#bundles[@]}" -eq 1 ] || { echo >&2 'Expected exactly one Kushion Patches MPP'; exit 1; }
cp "${bundles[0]}" "$output/kushion-patches.mpp"
python3 scripts/kushion_patches.py write --root "$output"
