#!/usr/bin/env bash
# Shared assertions for shell tests. Source this file; do not execute it directly.

_testlib_strip_annotations() {
  # Commands under test can legitimately emit GitHub workflow annotations. Keep
  # the diagnostic text without letting an expected rejection paint the job red.
  sed -E \
    -e $'s/\033\\[[0-9;]*[[:alpha:]]//g' \
    -e 's/^::error::/captured error: /' \
    -e 's/^::warning::/captured warning: /' \
    -e 's/^::notice::/captured notice: /'
}

_testlib_replay_captured() {
  local log=$1
  [ -s "$log" ] || return 0
  _testlib_strip_annotations < "$log" >&2
}

_testlib_pass_expected_failure() {
  local description=$1 status=$2
  if [ -n "${GITHUB_REPOSITORY-}" ]; then
    printf '::notice::tests [PASS] Expected rejection observed: %s (exit %s)\n' "$description" "$status" >&2
  else
    printf '[PASS] Expected rejection observed: %s (exit %s)\n' "$description" "$status" >&2
  fi
}

_testlib_fail_expected_failure() {
  local message=$1
  if [ -n "${GITHUB_REPOSITORY-}" ]; then
    printf '::error::tests [FAIL] %s\n' "$message" >&2
  else
    printf '[FAIL] %s\n' "$message" >&2
  fi
}

_expect_failure_impl() {
  local description=$1 expected_status=$2 expected_pattern=$3
  shift 3
  local log status
  log=$(mktemp "${TMPDIR:-/tmp}/patched-kushion-expected-failure.XXXXXX")

  if "$@" >"$log" 2>&1; then
    status=0
  else
    status=$?
  fi

  if [ "$status" -eq 0 ]; then
    _testlib_fail_expected_failure "Expected rejection but command succeeded: $description"
    _testlib_replay_captured "$log"
    rm -f "$log"
    return 1
  fi

  if [ -n "$expected_status" ] && [ "$status" -ne "$expected_status" ]; then
    _testlib_fail_expected_failure "Expected exit $expected_status but got $status: $description"
    _testlib_replay_captured "$log"
    rm -f "$log"
    return 1
  fi

  if [ -n "$expected_pattern" ] && ! grep -Eq -- "$expected_pattern" "$log"; then
    _testlib_fail_expected_failure "Command failed for an unexpected reason: $description"
    printf 'Expected output matching: %s\n' "$expected_pattern" >&2
    _testlib_replay_captured "$log"
    rm -f "$log"
    return 1
  fi

  if [ -n "$expected_pattern" ]; then
    grep -Em1 -- "$expected_pattern" "$log" | _testlib_strip_annotations | sed 's/^/expected rejection detail: /' >&2 || :
  fi
  rm -f "$log"
  _testlib_pass_expected_failure "$description" "$status"
}

expect_failure() {
  local description=$1
  shift
  _expect_failure_impl "$description" '' '' "$@"
}

expect_failure_status() {
  local description=$1 expected_status=$2
  shift 2
  _expect_failure_impl "$description" "$expected_status" '' "$@"
}

expect_failure_matching() {
  local description=$1 expected_status=$2 expected_pattern=$3
  shift 3
  _expect_failure_impl "$description" "$expected_status" "$expected_pattern" "$@"
}
