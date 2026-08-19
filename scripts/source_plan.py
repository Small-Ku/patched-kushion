#!/usr/bin/env python3
"""Select the smallest stock artifact set that covers requested build branches."""
from __future__ import annotations

import argparse
import itertools
import json
import re
from pathlib import Path
from typing import Any

BUILD_ARCHES = ("universal", "arm64-v8a", "arm-v7a", "x86_64", "x86")
ANDROID_TO_BUILD = {"arm64-v8a": "arm64-v8a", "armeabi-v7a": "arm-v7a", "x86_64": "x86_64", "x86": "x86"}
DPI = {"ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240, "xhdpi": 320, "xxhdpi": 480, "xxxhdpi": 640}


def requested_arches(raw: Any) -> tuple[list[str], set[str], set[str], set[str]]:
    if not isinstance(raw, list):
        raise SystemExit("arches JSON must be an array")
    out: list[str] = []
    required: set[str] = set()
    desired: set[str] = set()
    optional: set[str] = set()
    for item in raw:
        if isinstance(item, str):
            value = item
            priority = "required"
        elif isinstance(item, dict):
            value = item.get("arch")
            priority = str(item.get("sourcePriority") or ("desired" if item.get("optional", False) else "required"))
        else:
            value = None
            priority = "required"
        if value not in BUILD_ARCHES:
            raise SystemExit(f"unsupported build architecture in source plan: {value!r}")
        if priority not in {"required", "desired", "optional"}:
            raise SystemExit(f"unsupported source priority for {value!r}: {priority!r}")
        if value not in out:
            out.append(value)
        if priority == "required":
            required.add(value)
        elif priority == "desired":
            desired.add(value)
        else:
            optional.add(value)
    if not out:
        raise SystemExit("source plan requires at least one architecture")
    return out, required, desired, optional


def descriptor_build_arches(descriptor: str) -> set[str]:
    text = descriptor.strip().lower()
    if text == "universal":
        return set(BUILD_ARCHES)
    if text == "noarch":
        return {"universal"}
    tokens = {
        ANDROID_TO_BUILD[token]
        for token in re.split(r"[+,/\s]+", text)
        if token in ANDROID_TO_BUILD
    }
    if len(tokens) >= 2:
        tokens.add("universal")
    return tokens


def artifact_build_arches(fmt: str, descriptor: str) -> set[str]:
    """Return build branches that can be *derived* from one source artifact.

    Store architecture labels normally describe runtime compatibility.  That is
    not the same thing as our ability to derive an ABI-specific distribution
    artifact.  A fat standalone APK can be installed on several ABIs, but after
    the store has flattened a split bundle we no longer know which resources
    belonged to each ABI split.  Therefore standalone APKs only provide:

    * universal/noarch/multi-ABI APK -> the universal branch;
    * single-ABI APK -> that one ABI branch.

    Split containers retain their partition boundaries, so their descriptor can
    advertise every branch the bundle can materialize.
    """
    fmt = fmt.strip().upper()
    arches = descriptor_build_arches(descriptor)
    if fmt != "APK":
        return arches
    text = descriptor.strip().lower()
    if text in {"universal", "noarch"} or "universal" in arches:
        return {"universal"}
    concrete = arches - {"universal"}
    if len(concrete) == 1:
        return concrete
    if len(concrete) >= 2:
        return {"universal"}
    return set()


def dpi_value(value: str) -> int | None:
    text = value.strip().lower()
    if text in DPI:
        return DPI[text]
    m = re.fullmatch(r"(\d+)(?:dpi)?", text)
    return int(m.group(1)) if m else None


def dpi_compatible(descriptor: str, requested: str) -> bool:
    if not requested:
        return True
    desc = descriptor.strip().lower()
    req = requested.strip().lower()
    if desc in {req, "nodpi", "anydpi"}:
        return True
    m = re.fullmatch(r"(\d+)-(\d+)dpi", desc)
    value = dpi_value(req)
    return bool(m and value is not None and int(m.group(1)) <= value <= int(m.group(2)))


def sdk_score(descriptor: str) -> int:
    m = re.search(r"android\s+(\d+)(?:\.(\d+))?", descriptor.lower())
    if not m:
        return 0
    return 5000 - int(m.group(1)) * 100 - int(m.group(2) or 0)


def dpi_breadth(descriptor: str) -> int:
    desc = descriptor.strip().lower()
    if desc in {"nodpi", "anydpi"}:
        return 3000
    m = re.fullmatch(r"(\d+)-(\d+)dpi", desc)
    if m:
        lo, hi = map(int, m.groups())
        return 2000 + hi - lo + 640 - lo
    return 1000 if dpi_value(desc) is not None else 0


def row_score(row: dict[str, Any], coverage: set[str]) -> int:
    fmt = str(row.get("format", "")).upper()
    bundle = 1 if fmt == "BUNDLE" else 0
    breadth = len(artifact_build_arches(fmt, str(row.get("arch", ""))))
    return bundle * 10_000_000 + len(coverage) * 1_000_000 + breadth * 100_000 + sdk_score(str(row.get("minAndroid", ""))) * 10 + dpi_breadth(str(row.get("dpi", "")))


def select(
    inventory: list[Any], arches: list[str], required: set[str], desired: set[str], optional: set[str], dpi: str
) -> dict[str, Any]:
    requested = set(arches)
    candidates: list[dict[str, Any]] = []
    for index, raw in enumerate(inventory):
        if not isinstance(raw, dict):
            continue
        fmt = str(raw.get("format", "")).upper()
        if fmt not in {"APK", "BUNDLE"} or not str(raw.get("url", "")):
            continue
        if not dpi_compatible(str(raw.get("dpi", "")), dpi):
            continue
        coverage = requested & artifact_build_arches(fmt, str(raw.get("arch", "")))
        if not coverage:
            continue
        row = dict(raw)
        row["id"] = f"artifact-{index + 1}"
        row["coverage"] = sorted(coverage, key=BUILD_ARCHES.index)
        row["score"] = row_score(row, coverage)
        candidates.append(row)

    # Required branches are a hard boundary. Optional branches are best-effort:
    # maximize useful branch coverage first, then minimize downloads, then prefer
    # BUNDLEs and broader compatibility descriptors. This prevents one optional
    # x86 branch from rejecting an otherwise ideal ARM/universal APKMirror bundle.
    best: tuple[tuple[int, int, int, int, int, int], tuple[dict[str, Any], ...], set[str]] | None = None
    max_size = min(len(candidates), len(requested))
    for size in range(1, max_size + 1):
        for combo in itertools.combinations(candidates, size):
            covered: set[str] = set()
            for row in combo:
                covered.update(row["coverage"])
            if not required.issubset(covered):
                continue
            # Required coverage is a hard gate. Among valid plans, maximize
            # desired (auto-discovered) branches before true optional branches,
            # then minimize the number of downloads and prefer broader bundles.
            rank = (
                len(covered & desired),
                len(covered & optional),
                len(covered),
                -size,
                sum(int(row["score"]) for row in combo),
                -sum(len(str(row.get("url", ""))) for row in combo),
            )
            if best is None or rank > best[0]:
                best = (rank, combo, covered)

    if best is None:
        return {
            "schemaVersion": 1,
            "complete": False,
            "requestedArches": arches,
            "requiredArches": sorted(required, key=BUILD_ARCHES.index),
            "desiredArches": sorted(desired, key=BUILD_ARCHES.index),
            "optionalArches": sorted(optional, key=BUILD_ARCHES.index),
            "availableBuildArches": [],
            "missingDesiredArches": [arch for arch in arches if arch in desired],
            "missingOptionalArches": [arch for arch in arches if arch in optional],
            "artifacts": [],
        }

    covered = best[2]
    selected = [dict(row) for row in best[1]]
    branch_sources = {}
    for arch in arches:
        choices = [row for row in selected if arch in row["coverage"]]
        if choices:
            branch_sources[arch] = max(choices, key=lambda row: int(row["score"]))["id"]
    missing_desired = [arch for arch in arches if arch not in covered and arch in desired]
    missing_optional = [arch for arch in arches if arch not in covered and arch in optional]
    return {
        "schemaVersion": 1,
        "complete": required.issubset(covered) and bool(covered),
        "requestedArches": arches,
        "requiredArches": sorted(required, key=BUILD_ARCHES.index),
        "desiredArches": sorted(desired, key=BUILD_ARCHES.index),
        "optionalArches": sorted(optional, key=BUILD_ARCHES.index),
        "availableBuildArches": [arch for arch in arches if arch in covered],
        "missingDesiredArches": missing_desired,
        "missingOptionalArches": missing_optional,
        "artifactCount": len(selected),
        "artifacts": selected,
        "branchSources": branch_sources,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--inventory", type=Path, required=True)
    p.add_argument("--arches-json", required=True)
    p.add_argument("--dpi", default="")
    p.add_argument("--output", type=Path)
    a = p.parse_args()
    inventory = json.loads(a.inventory.read_text())
    if not isinstance(inventory, list):
        raise SystemExit("inventory must be a JSON array")
    arches, required, desired, optional = requested_arches(json.loads(a.arches_json))
    payload = select(inventory, arches, required, desired, optional, a.dpi)
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if a.output:
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.write_text(rendered)
    print(rendered, end="")


if __name__ == "__main__":
    main()
