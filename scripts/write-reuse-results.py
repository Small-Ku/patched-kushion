#!/usr/bin/env python3
"""Materialize planner-pruned reuse entries as ordinary variant result handoffs."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid reuse manifest {path}: {exc}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--output-dir", type=Path, required=True)
    args = ap.parse_args()

    manifest = load(args.manifest)
    rows = manifest.get("reused") if isinstance(manifest, dict) else None
    if not isinstance(rows, list):
        raise SystemExit("reuse manifest must contain a reused array")

    for row in rows:
        if not isinstance(row, dict):
            raise SystemExit("reuse manifest contains a non-object row")
        variant = row.get("variant")
        reuse = variant.get("reuse") if isinstance(variant, dict) else None
        input_id = str(variant.get("inputId", "")) if isinstance(variant, dict) else ""
        version = str(row.get("version", ""))
        if (
            not isinstance(variant, dict)
            or not isinstance(reuse, dict)
            or reuse.get("inputId") != input_id
            or str(variant.get("selectedVersion", "")) != version
        ):
            raise SystemExit("reuse manifest contains an invalid reusable variant")
        asset_id = reuse.get("assetId")
        asset_name = str(reuse.get("assetName", ""))
        result_key = str(variant.get("resultKey", ""))
        if not isinstance(asset_id, int) or not asset_name or not result_key:
            raise SystemExit("reusable variant is missing its release asset identity")
        output = args.output_dir / result_key
        output.mkdir(parents=True, exist_ok=True)
        result = {
            "schemaVersion": 1,
            "key": result_key,
            "variantKey": variant["key"],
            "inputId": input_id,
            "target": str(row.get("target", "")),
            "arch": str(row.get("arch", "")),
            "mode": variant["mode"],
            "version": version,
            "status": "reused",
            "reused": True,
            "sourceAssetId": asset_id,
            "assetName": asset_name,
            "sha256": str(reuse.get("sha256", "")).upper(),
            "sourceReleaseTag": str(reuse.get("releaseTag", "")),
        }
        (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
