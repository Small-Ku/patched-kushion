#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$root/tests/testlib.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
GITHUB_REPOSITORY=Small-Ku/patched-kushion

expected_rejection() {
  printf 'ordinary diagnostic before rejection\n' >&2
  printf '::error::fixture rejection\n' >&2
  return 7
}

unexpected_success() {
  printf 'command incorrectly succeeded\n'
  return 0
}

wrong_rejection() {
  printf '::error::different failure reason\n' >&2
  return 8
}

expect_failure_matching \
  'accept the expected fixture rejection' 7 'fixture rejection' \
  expected_rejection >"$tmp/pass.log" 2>&1

grep -Fq '::notice::tests [PASS] Expected rejection observed: accept the expected fixture rejection (exit 7)' "$tmp/pass.log"
grep -Fq 'expected rejection detail: captured error: fixture rejection' "$tmp/pass.log"
if grep -Fq '::error::fixture rejection' "$tmp/pass.log"; then
  echo 'expected rejection leaked a GitHub error annotation' >&2
  exit 1
fi

if expect_failure 'reject unexpected success' unexpected_success >"$tmp/success.log" 2>&1; then
  echo 'unexpected command success was accepted' >&2
  exit 1
fi
grep -Fq '::error::tests [FAIL] Expected rejection but command succeeded: reject unexpected success' "$tmp/success.log"

if expect_failure_matching 'reject the wrong failure reason' 7 'wanted reason' wrong_rejection >"$tmp/wrong.log" 2>&1; then
  echo 'wrong failure reason was accepted' >&2
  exit 1
fi
grep -Fq '::error::tests [FAIL] Expected exit 7 but got 8: reject the wrong failure reason' "$tmp/wrong.log"
grep -Fq 'captured error: different failure reason' "$tmp/wrong.log"

echo 'expected-failure assertion helper test passed'
