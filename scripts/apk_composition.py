#!/usr/bin/env python3
"""Summarize the compressed ZIP contents of a final APK."""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import zipfile
from typing import Any


CATEGORIES = (
    "nativeLibraries",
    "dex",
    "assets",
    "resources",
    "resourcesArsc",
    "metaInf",
    "other",
)


def classify_entry(name: str) -> str:
    normalized = name.replace("\\", "/")
    parts = normalized.split("/")
    upper_name = normalized.upper()
    if len(parts) >= 3 and parts[0] == "lib" and parts[-1].lower().endswith(".so"):
        return "nativeLibraries"
    if len(parts) == 1 and parts[-1].lower().endswith(".dex") and (
        parts[-1].lower() == "classes.dex"
        or parts[-1].lower().startswith("classes")
    ):
        return "dex"
    if normalized == "assets/" or normalized.startswith("assets/"):
        return "assets"
    if normalized == "resources.arsc":
        return "resourcesArsc"
    if normalized == "res/" or normalized.startswith("res/"):
        return "resources"
    if normalized == "META-INF/" or normalized.startswith("META-INF/") or upper_name.startswith("META-INF/"):
        return "metaInf"
    return "other"


def inspect_apk(path: Path) -> dict[str, Any]:
    """Return deterministic compressed and uncompressed ZIP payload totals."""
    compressed: dict[str, int] = defaultdict(int)
    uncompressed: dict[str, int] = defaultdict(int)
    entries: dict[str, int] = defaultdict(int)
    native_by_abi: dict[str, int] = defaultdict(int)
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if item.is_dir():
                continue
            category = classify_entry(item.filename)
            compressed[category] += item.compress_size
            uncompressed[category] += item.file_size
            entries[category] += 1
            parts = item.filename.replace("\\", "/").split("/")
            if category == "nativeLibraries" and len(parts) >= 3:
                native_by_abi[parts[1]] += item.compress_size

    total = sum(compressed.values())
    return {
        "schemaVersion": 1,
        "basis": "ZIP entry compressed sizes; container bytes include ZIP metadata, alignment padding, and any APK signing block",
        "fileSizeBytes": path.stat().st_size,
        "totalCompressedBytes": total,
        "totalUncompressedBytes": sum(uncompressed.values()),
        "containerBytes": max(0, path.stat().st_size - total),
        "categories": {
            key: {
                "compressedBytes": compressed[key],
                "uncompressedBytes": uncompressed[key],
                "entryCount": entries[key],
                "percentOfCompressedPayload": round(compressed[key] * 100 / total, 2) if total else 0.0,
            }
            for key in CATEGORIES
        },
        "nativeLibrariesByAbi": {
            key: native_by_abi[key] for key in sorted(native_by_abi)
        },
    }
