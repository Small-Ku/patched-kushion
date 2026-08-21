#!/usr/bin/env python3
"""Normalize Aptoide app/get and legacy getMeta responses.

Aptoide's v7 app/get endpoint can expose a current metadata node plus historical
versions.  This adapter keeps parsing pure and deterministic so CI can select an
exact version before downloading any stock bytes.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Iterable

ARCH_ALIASES = {
    "arm-v7a": "armeabi-v7a",
    "arm64-v8a": "arm64-v8a",
    "x86": "x86",
    "x86_64": "x86_64",
}
UNIVERSAL_MARKERS = {"universal", "unlimited", "noarch", "all"}


def load(path: str) -> dict[str, Any]:
    if path == "-":
        value = json.load(sys.stdin)
    else:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit("Aptoide response must be an object")
    return value


def _as_rows(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, list):
        for row in value:
            if isinstance(row, dict):
                yield row
    elif isinstance(value, dict):
        # Some API generations wrap node lists in data/datalist containers.
        for key in ("list", "data"):
            nested = value.get(key)
            if isinstance(nested, list):
                yield from _as_rows(nested)
        datalist = value.get("datalist")
        if isinstance(datalist, dict):
            yield from _as_rows(datalist.get("list"))


def candidate_rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    nodes = data.get("nodes") if isinstance(data.get("nodes"), dict) else {}
    candidates: list[dict[str, Any]] = []
    if isinstance(nodes, dict):
        meta = nodes.get("meta")
        if isinstance(meta, dict) and isinstance(meta.get("data"), dict):
            candidates.append(meta["data"])
        versions_node = nodes.get("versions")
        if isinstance(versions_node, dict):
            candidates.extend(_as_rows(versions_node))
    # Legacy app/getMeta response.
    if isinstance(data.get("data"), dict):
        candidates.append(data["data"])

    for row in candidates:
        file = row.get("file")
        if not isinstance(file, dict):
            # Historical node rows can occasionally be file-shaped directly.
            if any(key in row for key in ("vername", "path", "path_alt")):
                file = row
            else:
                continue
        version = str(file.get("vername") or row.get("vername") or "").strip().lstrip("v")
        path = str(file.get("path") or file.get("path_alt") or row.get("path") or "").strip()
        package = str(row.get("package") or data.get("data", {}).get("package") or "").strip()
        if not version or not path:
            continue
        key = (version, path, str(file.get("vercode") or row.get("vercode") or ""))
        if key in seen:
            continue
        seen.add(key)
        hardware = file.get("hardware") if isinstance(file.get("hardware"), dict) else {}
        cpus_raw = hardware.get("cpus") if isinstance(hardware, dict) else []
        if isinstance(cpus_raw, str):
            cpus = [part.strip().lower() for part in cpus_raw.replace("+", ",").split(",") if part.strip()]
        elif isinstance(cpus_raw, list):
            cpus = [str(part).strip().lower() for part in cpus_raw if str(part).strip()]
        else:
            cpus = []
        aab = row.get("aab")
        out.append({
            "packageName": package,
            "version": version,
            "versionCode": file.get("vercode") or row.get("vercode"),
            "url": path,
            "urlAlt": str(file.get("path_alt") or ""),
            "md5": str(file.get("md5sum") or ""),
            "architectures": cpus,
            "aab": aab if isinstance(aab, dict) else None,
            "format": "AAB" if isinstance(aab, dict) else "APK",
        })
    return out


def versions(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for row in candidate_rows(data):
        value = str(row["version"])
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out


def score(row: dict[str, Any], requested_arch: str) -> tuple[int, int, str] | None:
    cpus = set(str(v).lower() for v in row.get("architectures", []))
    if requested_arch == "universal":
        if not cpus or cpus & UNIVERSAL_MARKERS:
            arch_score = 1000
        elif len(cpus - UNIVERSAL_MARKERS) >= 2:
            arch_score = 800 + len(cpus)
        else:
            return None
    else:
        wanted = ARCH_ALIASES.get(requested_arch, requested_arch).lower()
        if wanted in cpus:
            arch_score = 1200 if len(cpus) == 1 else 1100 - len(cpus)
        elif not cpus or cpus & UNIVERSAL_MARKERS:
            arch_score = 500
        else:
            return None
    try:
        vercode = int(row.get("versionCode") or 0)
    except (TypeError, ValueError):
        vercode = 0
    # Prefer standalone APK rows until dynamic AAB split acquisition is proven.
    format_score = 0 if row.get("format") == "APK" else -200
    return arch_score + format_score, vercode, str(row.get("url", ""))


def select(data: dict[str, Any], version: str, arch: str) -> dict[str, Any] | None:
    wanted = version.strip().lstrip("v")
    matches: list[tuple[tuple[int, int, str], dict[str, Any]]] = []
    for row in candidate_rows(data):
        if row.get("version") != wanted:
            continue
        row_score = score(row, arch)
        if row_score is not None:
            matches.append((row_score, row))
    if not matches:
        return None
    return max(matches, key=lambda pair: pair[0])[1]


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
    row = select(data, ns.version, ns.arch)
    if row is None:
        return 1
    print(json.dumps(row, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
