#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

# shellcheck disable=SC1091
source utils.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'primary patched apk\n' >"$tmp/input.apk"

captured="$tmp/args"
patch_apk() {
  local input=$1 output=$2 args=$3 cli=$4 patches=$5
  printf '%s\n%s\n%s\n%s\n%s\n' "$input" "$output" "$args" "$cli" "$patches" >"$captured"
  cp -f "$input" "$output"
}

apply_auxiliary_package_identity \
  "$tmp/input.apk" "$tmp/output.apk" de.kwoo.shion.x 'Clone app' \
  "$tmp/morphe.jar" "$tmp/morphe.mpp"

test -s "$tmp/output.apk"
mapfile -t actual <"$captured"
test "${actual[0]}" = "$tmp/input.apk"
test "${actual[1]}" = "$tmp/output.apk"
test "${actual[2]}" = '--exclusive -e "Clone app" -OpackageName=de.kwoo.shion.x'
test "${actual[3]}" = "$tmp/morphe.jar"
test "${actual[4]}" = "$tmp/morphe.mpp"

if apply_auxiliary_package_identity "$tmp/input.apk" "$tmp/bad.apk" '' 'Clone app' "$tmp/morphe.jar" "$tmp/morphe.mpp" 2>/dev/null; then
  echo >&2 'empty auxiliary package identity unexpectedly accepted'
  exit 1
fi

if apply_auxiliary_package_identity "$tmp/input.apk" "$tmp/bad.apk" de.kwoo.shion.x '' "$tmp/morphe.jar" "$tmp/morphe.mpp" 2>/dev/null; then
  echo >&2 'empty auxiliary package patch unexpectedly accepted'
  exit 1
fi

echo 'auxiliary package identity test passed'
