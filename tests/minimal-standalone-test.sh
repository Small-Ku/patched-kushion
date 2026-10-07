#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/minimal-standalone-test.py

# Exercise the composition boundary. External tools are replaced here; the
# Python tests above verify the topology and resource decisions themselves.
source utils.sh
source tests/testlib.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp"
mkdir -p "$tmp/signed"
printf base > "$tmp/signed/base.apk"
printf abi > "$tmp/signed/abi.apk"
printf locale > "$tmp/signed/locale.apk"
ensure_apkeditor() { printf '%s\n' fixture.jar; }
resolve_aapt2() { printf '%s\n' fixture-aapt2; }
sign_apk() { echo 'Stock must not sign' >&2; return 99; }
selections=0 verifies=0
reject_selection=false
reject_verification=false
python3() {
  local command=$2 selected_dir='' output_dir='' arch=''
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --selected-dir) selected_dir=$2 ;;
      --output-dir) output_dir=$2 ;;
      --arch) arch=$2 ;;
    esac
    shift 2
  done
  case "$command" in
    standalone)
      selections=$((selections + 1))
      [ "$reject_selection" = false ] || return 1
      [ "$arch" = arm64-v8a ]
      cp "$selected_dir/base.apk" "$output_dir/"
      cp "$selected_dir/abi.apk" "$output_dir/"
      ;;
    verify-standalone)
      verifies=$((verifies + 1))
      [ "$reject_verification" = false ]
      ;;
    *) return 99 ;;
  esac
}
java() {
  local selected_dir='' output=''
  printf merge >> "$tmp/merges"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -i) selected_dir=$2; shift ;;
      -o) output=$2; shift ;;
    esac
    shift
  done
  if [ "$selected_dir" = "$tmp/signed" ]; then
    [ -f "$selected_dir/locale.apk" ]
  else
    [ -f "$selected_dir/base.apk" ]
    [ -f "$selected_dir/abi.apk" ]
    [ ! -f "$selected_dir/locale.apk" ]
  fi
  printf merged > "$output"
}
merge_split_dir_unsigned "$tmp/signed" "$tmp/concrete.apk" arm64-v8a minimal
[ "$selections" = 1 ] && [ "$verifies" = 1 ]
merge_split_dir_unsigned "$tmp/signed" "$tmp/universal.apk" universal
[ "$selections" = 1 ] && [ "$verifies" = 1 ]
reject_selection=true
expect_failure_matching 'reject unproven topology before merge' 1 'topology could not be proven' \
  merge_split_dir_unsigned "$tmp/signed" "$tmp/rejected.apk" arm64-v8a minimal
[ ! -f "$tmp/rejected.apk" ]
[ "$(cat "$tmp/merges")" = mergemerge ]
reject_selection=false
reject_verification=true
expect_failure 'discard a merged APK that still requires splits' \
  merge_split_dir_unsigned "$tmp/signed" "$tmp/invalid.apk" arm64-v8a minimal
[ ! -f "$tmp/invalid.apk" ]
[ "$(cat "$tmp/merges")" = mergemergemerge ]
echo 'minimal composition, universal fallback and fail-closed boundary test passed'
