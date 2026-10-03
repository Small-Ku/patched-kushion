#!/usr/bin/env python3
"""Turn a just-published build manifest into a deterministic F-Droid trigger."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import tomllib
from typing import Any


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"publication manifest not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid publication manifest {path}: {exc}") from exc


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", type=Path, required=True)
    ap.add_argument("--publication", type=Path, required=True)
    args = ap.parse_args()

    try:
        config = tomllib.loads(args.config.read_text(encoding="utf-8"))
    except (FileNotFoundError, tomllib.TOMLDecodeError) as exc:
        raise SystemExit(f"could not load {args.config}: {exc}") from exc

    fdroid = config.get("fdroid")
    if not isinstance(fdroid, dict):
        raise SystemExit(f"{args.config}: missing [fdroid] configuration")
    include_built = fdroid.get("include-built-releases", True)
    if not isinstance(include_built, bool):
        raise SystemExit(f"{args.config}: fdroid.include-built-releases must be boolean")
    limit = fdroid.get("max-repo-asset-size")
    if limit is not None and (not isinstance(limit, int) or isinstance(limit, bool) or limit < 1):
        raise SystemExit(f"{args.config}: fdroid.max-repo-asset-size must be a positive byte count")

    payload = load_json(args.publication)
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise SystemExit(f"unsupported publication manifest: {args.publication}")
    raw_assets = payload.get("assets", [])
    if not isinstance(raw_assets, list):
        raise SystemExit(f"invalid assets array in {args.publication}")

    eligible: list[dict[str, Any]] = []
    oversized: list[dict[str, Any]] = []
    for raw in raw_assets:
        if not isinstance(raw, dict) or str(raw.get("mode", "")) != "apk":
            continue
        name = str(raw.get("assetName", ""))
        asset_id = raw.get("assetId")
        size = raw.get("size")
        if not name.lower().endswith(".apk") or not isinstance(asset_id, int) or isinstance(asset_id, bool):
            raise SystemExit(f"invalid published APK record in {args.publication}: {raw!r}")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise SystemExit(f"published APK has no valid size: {name}")
        if limit is not None and size > limit:
            oversized.append(raw)
        else:
            eligible.append(raw)

    if not include_built:
        eligible = []

    if eligible:
        print("F-Droid-eligible APKs published by this pipeline run:")
        for raw in eligible:
            print(
                f"  + {raw['assetName']} (asset {raw['assetId']}, {raw['size']} bytes, "
                f"{raw.get('target', '?')} {raw.get('version', '?')} {raw.get('arch', '?')})"
            )
    if oversized:
        print("Published APKs retained on GitHub Release but excluded by the F-Droid Git size gate:")
        for raw in oversized:
            reason = f"{raw['size']} bytes > {limit}"
            print(f"  - {raw['assetName']} ({reason}; excluded, Git size guard remains active)")
            composition = raw.get("apkComposition")
            categories = composition.get("categories") if isinstance(composition, dict) else None
            if isinstance(categories, dict):
                major = sorted(
                    ((str(name), row.get("compressedBytes", 0)) for name, row in categories.items() if isinstance(row, dict)),
                    key=lambda item: (-int(item[1]), item[0]),
                )
                print("    ZIP compressed bytes: " + ", ".join(f"{name}={size}" for name, size in major))
                print(f"    APK container bytes outside ZIP entries: {composition.get('containerBytes', 0)}")

    # Oversized built APKs do not enter the repo, but still need an F-Droid
    # provenance update so the publication decision remains inspectable.
    changed = bool(eligible or (oversized and include_built))
    print(f"changed={1 if changed else 0}")


if __name__ == "__main__":
    main()
