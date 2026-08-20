#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description="Write a metadata-only failed variant result for publication diagnostics.")
p.add_argument("--variant-json", required=True)
p.add_argument("--target", required=True)
p.add_argument("--arch", required=True)
p.add_argument("--version", required=True)
p.add_argument("--status-file", type=Path, required=True)
p.add_argument("--output-dir", type=Path, required=True)
a = p.parse_args()

variant = json.loads(a.variant_json)
if not isinstance(variant, dict):
    raise SystemExit("variant JSON must be an object")
try:
    status = json.loads(a.status_file.read_text())
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"could not read failed patch status: {exc}")
if not isinstance(status, dict) or status.get("status") != "failed":
    raise SystemExit("failed variant result requires a failed patch status")

input_id = str(variant.get("inputId", ""))
result_key = str(variant.get("resultKey", ""))
variant_key = str(variant.get("key", ""))
mode = str(variant.get("mode", ""))
if not all((input_id, result_key, variant_key, mode)):
    raise SystemExit("variant JSON is missing result identity")

reason = str(status.get("reason") or "patch candidate failed before packaging")
category = str(status.get("category") or "build-failed")
failure_class = str(status.get("failureClass") or "unknown")
compatibility = str(variant.get("compatibility") or status.get("compatibility") or "declared")
try:
    traversal_index = int(variant.get("traversalIndex", status.get("traversalIndex", 0)) or 0)
except (TypeError, ValueError):
    traversal_index = 0

a.output_dir.mkdir(parents=True, exist_ok=True)
result = {
    "schemaVersion": 1,
    "status": "failed",
    "failed": True,
    "stage": "patch",
    "category": category,
    "failureClass": failure_class,
    "reason": reason,
    "compatibility": compatibility,
    "traversalIndex": traversal_index,
    "diagnostics": status.get("diagnostics") if isinstance(status.get("diagnostics"), dict) else {},
    "key": result_key,
    "variantKey": variant_key,
    "inputId": input_id,
    "target": a.target,
    "arch": a.arch,
    "mode": mode,
    "version": a.version,
}
(a.output_dir / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
