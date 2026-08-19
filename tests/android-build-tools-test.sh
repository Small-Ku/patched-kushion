#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

source tests/testlib.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sdk="$tmp/sdk"
build_tools="$sdk/build-tools/36.0.0"
mkdir -p "$build_tools"
for tool in aapt aapt2 apksigner zipalign; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$build_tools/$tool"
  chmod +x "$build_tools/$tool"
done

github_env="$tmp/github-env"
github_path="$tmp/github-path"
ANDROID_SDK_ROOT="$sdk" GITHUB_ENV="$github_env" GITHUB_PATH="$github_path" \
  scripts/ensure-android-build-tools.sh 36.0.0 >/dev/null

grep -Fx "ANDROID_BUILD_TOOLS_DIR=$build_tools" "$github_env" >/dev/null
grep -Fx "AAPT=$build_tools/aapt" "$github_env" >/dev/null
grep -Fx "AAPT2=$build_tools/aapt2" "$github_env" >/dev/null
grep -Fx "APKSIGNER=$build_tools/apksigner" "$github_env" >/dev/null
grep -Fx "ZIPALIGN=$build_tools/zipalign" "$github_env" >/dev/null
grep -Fx "$build_tools" "$github_path" >/dev/null

rm -f "$build_tools/zipalign"
mkdir -p "$sdk/cmdline-tools/latest/bin"
cat > "$sdk/cmdline-tools/latest/bin/sdkmanager" <<'SCRIPT'
#!/usr/bin/env bash
sleep 10
SCRIPT
chmod +x "$sdk/cmdline-tools/latest/bin/sdkmanager"

start=$(date +%s)
set +e
output=$(ANDROID_SDK_ROOT="$sdk" ANDROID_SDKMANAGER_TIMEOUT_SECONDS=1 \
  scripts/ensure-android-build-tools.sh 36.0.0 2>&1)
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))

if [ "$rc" -eq 0 ]; then
  echo >&2 "expected sdkmanager timeout to fail"
  exit 1
fi
if [ "$elapsed" -gt 5 ]; then
  echo >&2 "sdkmanager timeout was not bounded: ${elapsed}s"
  exit 1
fi
if ! grep -Eq 'timed out|sdkmanager failed' <<<"$output"; then
  echo >&2 "missing bounded sdkmanager failure diagnostic"
  printf '%s\n' "$output" >&2
  exit 1
fi

set +e
output=$(ANDROID_SDK_ROOT="$sdk" ANDROID_SDKMANAGER_TIMEOUT_SECONDS=invalid \
  scripts/ensure-android-build-tools.sh 36.0.0 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! grep -Fq 'must be a positive integer' <<<"$output"; then
  echo >&2 "invalid sdkmanager timeout was not rejected"
  exit 1
fi

echo '[PASS] Android Build Tools selection is pinned and sdkmanager fallback is bounded'
