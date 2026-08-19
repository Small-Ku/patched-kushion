#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo >&2 "usage: $0 LOG COMMAND [ARG ...]"
  exit 2
fi

log=$1
shift
mkdir -p "$(dirname "$log")"

set +e
PATCHED_KUSHION_CAPTURE_FAILURE=true \
PATCHED_KUSHION_ERROR_ANNOTATION=plain \
  "$@" >"$log" 2>&1
status=$?
set -e

if [ -n "${GITHUB_OUTPUT-}" ]; then
  printf 'exit_code=%s\n' "$status" >> "$GITHUB_OUTPUT"
fi

if [ "$status" -eq 0 ]; then
  printf 'Captured build stage succeeded; full diagnostic log: %s\n' "$log"
else
  printf 'Captured build candidate exited %s; full diagnostic log is preserved at %s\n' "$status" "$log"
  printf '%s\n' '--- diagnostic tail ---'
  tail -n "${PATCHED_KUSHION_DIAGNOSTIC_TAIL_LINES:-24}" "$log" || true
  printf '%s\n' '--- end diagnostic tail ---'
fi

# Candidate success/failure is data for the DAG. The caller decides later
# whether the overall required publication set is healthy.
exit 0
