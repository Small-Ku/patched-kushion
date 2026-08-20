#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
out="$tmp/output"
log="$tmp/stage.log"
console="$tmp/console.log"
GITHUB_REPOSITORY=example/repo GITHUB_OUTPUT="$out" \
  "$root/scripts/capture-build-stage.sh" "$log" \
  bash -c 'source "$1/utils.sh"; TEMP_DIR=$(mktemp -d); abort "fixture candidate rejection"' bash "$root" \
  >"$console" 2>&1
[ "$(sed -n 's/^exit_code=//p' "$out")" = 1 ]
grep -Fq 'ABORT: fixture candidate rejection' "$log"
grep -Fq 'Captured build candidate exited 1' "$console"
! grep -Eq '^::(error|warning|notice)::' "$log"
! grep -Eq '^::(error|warning|notice)::' "$console"

# Source/stock/patch stages may recreate their output directory. The capture
# must survive that lifecycle and be materialized at the requested path only
# after the stage exits.
destructive_dir="$tmp/recreated-output"
destructive_log="$destructive_dir/acquisition.log"
destructive_out="$tmp/destructive-output"
destructive_console="$tmp/destructive-console.log"
GITHUB_OUTPUT="$destructive_out" RUNNER_TEMP="$tmp/runner-temp" \
  "$root/scripts/capture-build-stage.sh" "$destructive_log" \
  bash -c 'dir=$1; echo before-reset; rm -rf "$dir"; mkdir -p "$dir"; echo after-reset; exit 7' bash "$destructive_dir" \
  >"$destructive_console" 2>&1
[ "$(sed -n 's/^exit_code=//p' "$destructive_out")" = 7 ]
test -s "$destructive_log"
grep -Fq 'before-reset' "$destructive_log"
grep -Fq 'after-reset' "$destructive_log"
grep -Fq 'after-reset' "$destructive_console"
! grep -Fq 'cannot open' "$destructive_console"

echo 'captured candidate failure stays neutral and survives output-directory reset test passed'
