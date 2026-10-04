#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/patch-result"
cat > "$tmp/patch-result/skip.json" <<'JSON'
{"schemaVersion":1,"reason":"No compatible patch for version 9.8.1; KouTube optional architecture is unavailable."}
JSON

# Reproduce the original bug: exit 0 alone mapped this explicit skip to ready.
old_status=$(python3 - <<'PY'
patch_exit_code = 0
print("ready" if patch_exit_code == 0 else "failed")
PY
)
test "$old_status" = ready

optional_status=$(python3 "$root/scripts/patch_skip.py" --skip-file "$tmp/patch-result/skip.json" --optional true)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["status"]=="skipped" and d["outcome"]=="unavailable" and d["category"]=="patch-unavailable" and d["reason"]=="No compatible patch for version 9.8.1; KouTube optional architecture is unavailable."' "$optional_status"

required_status=$(python3 "$root/scripts/patch_skip.py" --skip-file "$tmp/patch-result/skip.json" --optional false)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["status"]=="failed" and d["category"]=="patch-required-unavailable"' "$required_status"

python3 - "$tmp/patch-result/status.json" "$optional_status" <<'PY'
import json, pathlib, sys
status = json.loads(sys.argv[2])
status.update({"schemaVersion": 1, "stage": "patch", "failureClass": "input", "target": "KouTube", "version": "9.8.1", "arch": "x86", "mode": "apk", "key": "koutube--9.8.1--x86--apk", "variantKey": "koutube--x86--apk", "compatibility": "declared", "traversalIndex": 0, "diagnostics": {}})
pathlib.Path(sys.argv[1]).write_text(json.dumps(status))
PY
variant='{"inputId":"input-123","resultKey":"koutube--9.8.1--x86--apk","key":"koutube--x86--apk","mode":"apk","optional":true,"compatibility":"declared","traversalIndex":0}'
python3 "$root/scripts/write-variant-failure.py" \
  --variant-json "$variant" --target KouTube --arch x86 --version 9.8.1 \
  --status-file "$tmp/patch-result/status.json" --output-dir "$tmp/build-result"
python3 - "$tmp/build-result/result.json" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["status"] == "skipped" and result["skipped"] is True and result["failed"] is False and result["category"] == "patch-unavailable"
PY

required_variant='{"inputId":"input-123","resultKey":"koutube--9.8.1--x86--apk","key":"koutube--x86--apk","mode":"apk","optional":false,"compatibility":"declared","traversalIndex":0}'
if python3 "$root/scripts/write-variant-failure.py" \
  --variant-json "$required_variant" \
  --target KouTube --arch x86 --version 9.8.1 \
  --status-file "$tmp/patch-result/status.json" --output-dir "$tmp/required-result" >/dev/null 2>&1; then
  echo "required variant was incorrectly allowed to skip" >&2
  exit 1
fi

python3 - "$root" <<'PY'
import importlib.util, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("publish_release", root / "scripts/publish_release.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
row = {"status": "skipped", "skipped": True}
assert module.publication_disposition({"optional": True}, row) == "unavailable"
assert module.publication_disposition({"optional": False}, row) == "pending"
workflow = (root / ".github/workflows/build-arch.yml").read_text()
package = workflow[workflow.index("\n  package:"):]
read_status = package[package.index("- name: Read Patch Status"):package.index("- name: Set Up Locked Toolchain")]
assert '.status == "skipped"' in read_status
assert "steps.patch_status.outputs.ready == 'true'" in workflow
assert "--optional \"$PATCH_OPTIONAL\"" in workflow
assert "hashFiles('patch-result/skip.json')" in workflow
PY
echo 'optional patch skip handoff, package gate, and publication health test passed'
