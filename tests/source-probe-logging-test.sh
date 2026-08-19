#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
# shellcheck source=../utils.sh
source utils.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
TEMP_DIR=$tmp
GITHUB_REPOSITORY=Small-Ku/patched-kushion

curl() { return 22; }

if _req https://example.invalid/stock - 2>"$tmp/default.log"; then
  echo >&2 "expected the default request to fail"
  exit 1
fi
grep -Fq '::error::utils.sh [-] Request failed: https://example.invalid/stock' "$tmp/default.log"

if REQUEST_FAILURE_LEVEL=notice _req https://example.invalid/stock - 2>"$tmp/probe.log"; then
  echo >&2 "expected the probe request to fail"
  exit 1
fi
grep -Fq 'utils.sh [i] Request failed: https://example.invalid/stock' "$tmp/probe.log"
if grep -Eq '^::(error|warning|notice)::' "$tmp/probe.log"; then
  echo >&2 "recoverable source probing emitted a workflow annotation"
  exit 1
fi
