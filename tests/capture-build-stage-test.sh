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
echo 'captured candidate failure stays neutral test passed'
