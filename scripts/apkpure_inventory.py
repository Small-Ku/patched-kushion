#!/usr/bin/env python3
"""Parse APKPure's history API and select exact-version ABI payloads.

The public history response contains one row per downloadable variant.  Treat
its architecture metadata as a selection hint only; downstream byte-level APK
and split validation remains authoritative.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ARCH_ALIASES = {
    "arm-v7a": "armeabi-v7a",
    "arm64-v8a": "arm64-v8a",
    "x86": "x86",
    "x86_64": "x86_64",
}
UNIVERSAL_MARKERS = {"universal", "unlimited", "noarch"}
SPLIT_TYPES = {"xapk", "apks", "apkm"}


def load(path: str) -> dict[str, Any]:
    if path == "-":
        value = json.load(sys.stdin)
    else:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit("APKPure history response must be an object")
    return value


def rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    raw = data.get("version_list")
    if not isinstance(raw, list):
        return []
    return [row for row in raw if isinstance(row, dict)]


def versions(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for row in rows(data):
        value = str(row.get("version_name") or "").strip().lstrip("v")
        if value and value not in seen:
            seen.add(value)
            out.append(value)
    return out


def native_codes(row: dict[str, Any]) -> list[str]:
    raw = row.get("native_code")
    if isinstance(raw, list):
        values = raw
    elif isinstance(raw, str):
        values = raw.replace("+", ",").replace(";", ",").split(",")
    else:
        values = []
    return [str(value).strip().lower() for value in values if str(value).strip()]


def asset(row: dict[str, Any]) -> tuple[str, str]:
    raw = row.get("asset")
    if not isinstance(raw, dict):
        return "", ""
    kind = str(raw.get("type") or "").strip().lower()
    url = str(raw.get("url") or "").strip()
    return kind, url


def score(row: dict[str, Any], requested_arch: str) -> tuple[int, int, str] | None:
    kind, url = asset(row)
    if not kind or not url:
        return None
    codes = native_codes(row)
    code_set = set(codes)
    split = kind in SPLIT_TYPES

    if requested_arch == "universal":
        if code_set & UNIVERSAL_MARKERS or not codes:
            arch_score = 1000
        elif split and len(code_set - UNIVERSAL_MARKERS) >= 2:
            arch_score = 800 + len(code_set)
        elif kind == "apk" and len(code_set - UNIVERSAL_MARKERS) >= 2:
            arch_score = 700 + len(code_set)
        else:
            return None
    else:
        wanted = ARCH_ALIASES.get(requested_arch, requested_arch).lower()
        if wanted in code_set:
            arch_score = 1200 if len(code_set) == 1 else 1100 - len(code_set)
        elif code_set & UNIVERSAL_MARKERS or not codes:
            # A universal split container can still be partitioned downstream.
            # A standalone APK is accepted only as a lower-priority candidate;
            # byte-level native-lib inspection will reject a false claim.
            arch_score = 850 if split else 500
        else:
            return None

    format_score = 100 if split else 0
    try:
        version_code = int(row.get("version_code") or 0)
    except (TypeError, ValueError):
        version_code = 0
    return arch_score + format_score, version_code, url


def select(data: dict[str, Any], version: str, arch: str) -> dict[str, Any] | None:
    wanted_version = version.strip().lstrip("v")
    candidates: list[tuple[tuple[int, int, str], dict[str, Any]]] = []
    for row in rows(data):
        value = str(row.get("version_name") or "").strip().lstrip("v")
        if value != wanted_version:
            continue
        candidate_score = score(row, arch)
        if candidate_score is not None:
            candidates.append((candidate_score, row))
    if not candidates:
        return None
    # Highest architecture/format score, then newest versionCode; URL provides
    # deterministic tie-breaking for malformed duplicate API rows.
    _, chosen = max(candidates, key=lambda pair: pair[0])
    kind, url = asset(chosen)
    return {
        "packageName": str(chosen.get("package_name") or ""),
        "version": wanted_version,
        "versionCode": chosen.get("version_code"),
        "architectures": native_codes(chosen),
        "format": kind.upper(),
        "url": url,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    vp = sub.add_parser("versions")
    vp.add_argument("--json", required=True)
    sp = sub.add_parser("select")
    sp.add_argument("--json", required=True)
    sp.add_argument("--version", required=True)
    sp.add_argument("--arch", required=True)
    ns = ap.parse_args()
    data = load(ns.json)
    if ns.command == "versions":
        for value in versions(data):
            print(value)
        return 0
    chosen = select(data, ns.version, ns.arch)
    if chosen is None:
        return 1
    print(json.dumps(chosen, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
