#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# Canonical pre-delivery/CI validation entry point. Run it through Pixi so the
# exact activation environment, Python and JVM that CI sees are part of the
# validation contract rather than an accidental property of the host shell.
if [ -z "${PIXI_PROJECT_ROOT:-}" ] || [ -z "${CONDA_PREFIX:-}" ]; then
  echo >&2 "ci-validate must run inside the activated Pixi environment (use: pixi run ci-validate)"
  exit 2
fi

if [ -z "${BCPROV_JAR:-}" ]; then
  if ! BCPROV_JAR=$(scripts/ensure-bcprov.sh); then
    echo >&2 "Unable to resolve the pinned Bouncy Castle provider required by repository validation"
    exit 2
  fi
  export BCPROV_JAR
fi

checks=0
passes=0
failures=()

run_check() {
  local name=$1
  shift
  checks=$((checks + 1))
  printf '\n==> %s\n' "$name"
  if "$@"; then
    passes=$((passes + 1))
  else
    local rc=$?
    failures+=("$name (exit $rc)")
    printf '[FAIL] %s (exit %s)\n' "$name" "$rc" >&2
  fi
}

run_check "locked Pixi runtime" scripts/toolchain-info.sh
run_check "shell syntax" bash -n build.sh build-termux.sh utils.sh scripts/*.sh tests/*.sh
run_check "Python syntax" python3 -m py_compile scripts/*.py

# Discover tests instead of mirroring a hand-maintained CI list. A new
# *-test.sh file therefore becomes a pre-delivery and GitHub gate immediately.
for test in tests/*-test.sh; do
  run_check "$test" "$test"
done

run_check "configuration and workflow contract" python3 scripts/validate-repository.py
run_check "unstaged whitespace errors" git diff --check
run_check "staged whitespace errors" git diff --cached --check

failed=${#failures[@]}
printf '\nRepository validation: %s/%s checks passed; %s failed.\n' "$passes" "$checks" "$failed"
if [ "$failed" -gt 0 ]; then
  printf 'Failed checks:\n' >&2
  printf '  - %s\n' "${failures[@]}" >&2
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '## Repository validation\n\n'
    printf -- '- Locked environment: `%s`\n' "${CONDA_PREFIX}"
    printf -- '- Checks: **%s passed / %s total**\n' "$passes" "$checks"
    printf -- '- Failed: **%s**\n' "$failed"
    if [ "$failed" -gt 0 ]; then
      printf '\n### Failed checks\n\n'
      for failure in "${failures[@]}"; do
        printf -- '- `%s`\n' "$failure"
      done
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$failed" -gt 0 ]; then
  exit 1
fi

echo '[PASS] repository pre-delivery validation completed under the locked Pixi environment'
