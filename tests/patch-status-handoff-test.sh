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
assert 'Fail Patch Variant' in text
assert 'Download Patch Handoff' in text
assert 'Read Patch Status' in text
assert "steps.patch_status.outputs.ready == 'true'" in text
assert 'Report Missing Patch Artifact' not in text
assert 'Download Patched APK' not in text
# Patch compatibility failures must be captured into a status handoff before
# the matrix leg is marked failed, instead of making Package probe a missing
# artifact and emit a second unrelated error.
apply = text.index('- name: Apply Patches')
write = text.index('- name: Write Patch Status')
upload = text.index('- name: Upload Patch Handoff')
fail = text.index('- name: Fail Patch Variant')
assert apply < write < upload < fail
segment = text[apply:write]
assert 'continue-on-error: true' in segment
PY
echo 'patch status handoff test passed'
