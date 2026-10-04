#!/usr/bin/env python3
"""Classify an explicit patch skip marker for the patch handoff."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-file", type=Path, required=True)
    parser.add_argument("--optional", choices=("true", "false"), required=True)
    args = parser.parse_args()

    try:
        marker = json.loads(args.skip_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"could not read patch skip marker: {exc}") from exc
    if not isinstance(marker, dict) or marker.get("schemaVersion") != 1:
        raise SystemExit("patch skip marker must be a schemaVersion 1 object")
    reason = marker.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise SystemExit("patch skip marker must contain a non-empty reason")

    optional = args.optional == "true"
    result = {
        "status": "skipped" if optional else "failed",
        "outcome": "unavailable" if optional else "failed",
        "reason": reason.strip(),
        "category": "patch-unavailable" if optional else "patch-required-unavailable",
        "failureClass": "input",
    }
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
