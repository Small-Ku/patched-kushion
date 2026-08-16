#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

python3 - <<'PY'
from pathlib import Path
import re
import sys

errors = []
for path in sorted(Path('.github/workflows').glob('*.y*ml')):
    lines = path.read_text().splitlines()
    in_jobs = False
    job_indent = None
    in_job_env = False
    env_indent = None

    for lineno, line in enumerate(lines, 1):
        stripped = line.lstrip(' ')
        indent = len(line) - len(stripped)

        if stripped == 'jobs:':
            in_jobs = True
            job_indent = None
            in_job_env = False
            continue
        if in_jobs and indent == 0 and stripped and not stripped.startswith('#'):
            in_jobs = False
            job_indent = None
            in_job_env = False

        if not in_jobs or not stripped or stripped.startswith('#'):
            continue

        # jobs.<job_id> keys are indented two spaces. Their job-level env block is
        # indented four spaces. runner.* is unavailable while GitHub evaluates
        # jobs.<job_id>.env, so reject it before a workflow reaches GitHub.
        if indent == 2 and re.match(r'^[A-Za-z0-9_.-]+:\s*$', stripped):
            job_indent = indent
            in_job_env = False
            env_indent = None
            continue

        if job_indent is not None and indent == 4 and stripped == 'env:':
            in_job_env = True
            env_indent = indent
            continue

        if in_job_env:
            if indent <= env_indent:
                in_job_env = False
                env_indent = None
            elif '${{ runner.' in line:
                errors.append(f'{path}:{lineno}: runner context is not available in jobs.<job_id>.env: {stripped}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    raise SystemExit(1)

print('[PASS] workflow job-level env contexts avoid runner.*')
PY
