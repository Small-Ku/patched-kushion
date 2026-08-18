#!/usr/bin/env python3
"""Validate reusable CI handoff directories before trusting an Actions cache."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"invalid cache metadata {path}: {exc}")
    if not isinstance(value, dict):
        raise SystemExit(f"invalid cache metadata object: {path}")
    return value


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                h.update(chunk)
    except OSError as exc:
        raise SystemExit(f"cannot read cached payload {path}: {exc}")
    return h.hexdigest().upper()


def validate_source(root: Path, version: str) -> None:
    meta = load(root / "source.json")
    if meta.get("status") != "ready":
        raise SystemExit("cached source inventory is not ready")
    coverage = meta.get("coverage", {})
    if not isinstance(coverage, dict) or coverage.get("missingRequired", []) != []:
        raise SystemExit("cached source inventory is missing required architecture coverage")
    available = meta.get("availableBuildArches", [])
    if not isinstance(available, list) or not available:
        raise SystemExit("cached source inventory has no available build architectures")
    actual_version = str(meta.get("version", ""))
    if actual_version and actual_version.lstrip("vV") != version.lstrip("vV"):
        raise SystemExit(f"cached source version mismatch: {actual_version} != {version}")
    if not any(path.is_file() for path in root.rglob("*.apk")):
        raise SystemExit("cached source inventory contains no APK payloads")
    if str(meta.get("strategy", "partition")) == "branches":
        for arch in available:
            branch = root / "branches" / str(arch)
            if not branch.is_dir() or not any(path.is_file() for path in branch.iterdir()):
                raise SystemExit(f"cached branch payload is missing for {arch}")


def validate_stock(root: Path, target: str, version: str, arch: str) -> None:
    if (root / "skip.json").is_file():
        meta = load(root / "skip.json")
        if meta.get("schemaVersion") != 1:
            raise SystemExit("cached stock skip marker has unsupported schema")
        if (str(meta.get("target", "")), str(meta.get("arch", ""))) != (target, arch):
            raise SystemExit("cached stock skip marker axes mismatch")
        return
    apk = root / "stock.apk"
    meta = load(root / "stock.json")
    security = load(root / "stock.security.json")
    if meta.get("schemaVersion") != 1:
        raise SystemExit("cached stock metadata has unsupported schema")
    expected_axes = (str(meta.get("target", "")), str(meta.get("version", "")), str(meta.get("arch", "")))
    if expected_axes != (target, version, arch):
        raise SystemExit(f"cached stock axes mismatch: {expected_axes!r}")
    digest = sha256(apk)
    if digest != str(meta.get("sha256", "")).upper():
        raise SystemExit("cached stock APK SHA-256 mismatch")
    if meta.get("stockValidated") is not True or meta.get("securityValidated") is not True:
        raise SystemExit("cached stock was not fully validated")
    if digest != str(security.get("artifactSha256", "")).upper():
        raise SystemExit("cached stock security fingerprint describes another APK")
    if str(meta.get("fingerprintSha256", "")).upper() != str(security.get("comparisonSha256", "")).upper():
        raise SystemExit("cached stock security comparison fingerprint mismatch")


def validate_patch(root: Path, target: str, version: str, arch: str, mode: str, profile: str) -> None:
    if (root / "skip.json").is_file():
        meta = load(root / "skip.json")
        if meta.get("schemaVersion") != 1:
            raise SystemExit("cached patch skip marker has unsupported schema")
        if (str(meta.get("target", "")), str(meta.get("arch", "")), str(meta.get("mode", ""))) != (target, arch, mode):
            raise SystemExit("cached patch skip marker axes mismatch")
        return
    apk = root / "patched.apk"
    meta = load(root / "patch.json")
    if meta.get("schemaVersion") != 1:
        raise SystemExit("cached patch metadata has unsupported schema")
    expected_axes = (
        str(meta.get("target", "")), str(meta.get("version", "")),
        str(meta.get("arch", "")), str(meta.get("mode", "")),
    )
    if expected_axes != (target, version, arch, mode):
        raise SystemExit(f"cached patch axes mismatch: {expected_axes!r}")
    if profile and str(meta.get("patchProfileHash", "")) != profile:
        raise SystemExit("cached patch profile mismatch")
    if sha256(apk) != str(meta.get("sha256", "")).upper():
        raise SystemExit("cached patched APK SHA-256 mismatch")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="kind", required=True)
    source = sub.add_parser("source")
    source.add_argument("--root", type=Path, required=True)
    source.add_argument("--version", required=True)
    stock = sub.add_parser("stock")
    stock.add_argument("--root", type=Path, required=True)
    stock.add_argument("--target", required=True)
    stock.add_argument("--version", required=True)
    stock.add_argument("--arch", required=True)
    patch = sub.add_parser("patch")
    patch.add_argument("--root", type=Path, required=True)
    patch.add_argument("--target", required=True)
    patch.add_argument("--version", required=True)
    patch.add_argument("--arch", required=True)
    patch.add_argument("--mode", required=True)
    patch.add_argument("--profile", default="")
    args = parser.parse_args()

    if args.kind == "source":
        validate_source(args.root, args.version)
    elif args.kind == "stock":
        validate_stock(args.root, args.target, args.version, args.arch)
    else:
        validate_patch(args.root, args.target, args.version, args.arch, args.mode, args.profile)


if __name__ == "__main__":
    main()
