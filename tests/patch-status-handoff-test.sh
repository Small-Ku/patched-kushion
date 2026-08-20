#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
python3 - <<'PY'
from pathlib import Path
text = Path('.github/workflows/build-arch.yml').read_text(encoding='utf-8')
assert 'id: patch_apply' in text
assert 'Write Patch Status' in text
assert 'Upload Patch Handoff' in text
assert 'Fail Patch Variant' not in text
assert 'Download Patch Handoff' in text
assert 'Read Patch Status' in text
assert "steps.patch_status.outputs.ready == 'true'" in text
assert 'Report Missing Patch Artifact' not in text
assert 'Download Patched APK' not in text
# Patch compatibility failures are captured as DAG data. The patch job stays
# successful long enough to upload a status handoff; final publication health
# decides whether any required variants remain pending.
apply = text.index('- name: Apply Patches')
write = text.index('- name: Write Patch Status')
upload = text.index('- name: Upload Patch Handoff')
report = text.index('- name: Report Rejected Patch Candidate')
assert apply < write < upload < report
segment = text[apply:write]
assert 'scripts/capture-build-stage.sh' in segment
assert 'continue-on-error: true' not in segment
PY
echo 'patch status handoff test passed'
