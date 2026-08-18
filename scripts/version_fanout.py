#!/usr/bin/env python3
"""Expand source-discovery versions into independent build fan-out nodes."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
from typing import Any


def load(path: Path) -> Any:
    return json.loads(path.read_text())


def sha_json(value: Any) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(raw).hexdigest()


def version_key(version: str) -> str:
    readable = re.sub(r"[^A-Za-z0-9._-]+", "-", version).strip("-._") or "version"
    readable = readable[:48]
    suffix = hashlib.sha256(version.encode()).hexdigest()[:8]
    return f"{readable}-{suffix}"


def candidate_rows(graph: dict[str, Any], arches: list[Any] | None = None) -> list[dict[str, Any]]:
    rows_by_version = {
        str(row.get("version")): row
        for row in graph.get("versions", [])
        if isinstance(row, dict) and row.get("version")
    }
    result: list[dict[str, str]] = []
    for value in graph.get("versionTraversal", []):
        version = str(value)
        row = rows_by_version.get(version, {})
        candidate: dict[str, Any] = {
            "version": version,
            "versionKey": version_key(version),
            "compatibility": str(row.get("compatibility", "declared")),
        }
        if arches is not None:
            expanded = []
            source_policies: set[str] = set()
            source_arches: list[dict[str, str]] = []
            for raw_branch in arches:
                if not isinstance(raw_branch, dict):
                    continue
                source_arches.append({
                    "arch": str(raw_branch.get("arch", "")),
                    "priority": str(raw_branch.get("sourcePriority", "required")),
                })
                for variant in raw_branch.get("variants", []):
                    if isinstance(variant, dict):
                        policy = str(variant.get("sourcePolicyHash", ""))
                        if policy:
                            source_policies.add(policy)
                        expanded.append(variant_for_version(variant, version, candidate["compatibility"], candidate["versionKey"]))
            if len(source_policies) != 1:
                raise SystemExit(f"version {version!r}: expected one source policy hash, got {len(source_policies)}")
            candidate["sourceCacheKey"] = sha_json({
                "schemaVersion": 1,
                "version": version,
                "sourcePolicyHash": next(iter(source_policies)),
                "arches": sorted(source_arches, key=lambda row: (row["arch"], row["priority"])),
            })
            candidate["allReusable"] = bool(expanded) and all(isinstance(variant.get("reuse"), dict) for variant in expanded)
        result.append(candidate)
    return result


def variant_for_version(variant: dict[str, Any], version: str, compatibility: str, key: str) -> dict[str, Any]:
    candidates = variant.get("candidateInputIds")
    input_id = str(candidates.get(version, "")) if isinstance(candidates, dict) else ""
    if not input_id:
        if compatibility != "forward-probe" or int(variant.get("forwardProbeLimit", 0) or 0) <= 0:
            raise SystemExit(f"{variant.get('key')}: version {version!r} is outside the allowed compatibility fan-out")
        base = str(variant.get("inputBase", ""))
        if not base:
            raise SystemExit(f"{variant.get('key')}: forward probe has no inputBase")
        input_id = sha_json({
            "base": base,
            "version": version,
            "arch": variant["arch"],
            "mode": variant["mode"],
        })

    reuse_index = variant.get("reuseByInputId")
    reuse = reuse_index.get(input_id) if isinstance(reuse_index, dict) else None
    out = dict(variant)
    out["inputId"] = input_id
    out["selectedVersion"] = version
    out["compatibility"] = compatibility
    out["resultKey"] = f"{variant['key']}--{key}"
    out["reuse"] = reuse if isinstance(reuse, dict) else None
    return out


def collect(graph: dict[str, Any], statuses_root: Path, arches: list[Any]) -> list[dict[str, Any]]:
    statuses: dict[str, dict[str, Any]] = {}
    for path in statuses_root.rglob("source-status.json"):
        row = load(path)
        if not isinstance(row, dict) or not row.get("version"):
            continue
        statuses[str(row["version"])] = row

    candidates = {row["version"]: row for row in candidate_rows(graph, arches)}
    result: list[dict[str, Any]] = []
    for version in graph.get("versionTraversal", []):
        version = str(version)
        status = statuses.get(version)
        if not isinstance(status, dict) or status.get("ready") is not True:
            continue
        candidate = candidates[version]
        for raw_branch in arches:
            if not isinstance(raw_branch, dict) or not isinstance(raw_branch.get("arch"), str):
                raise SystemExit("arches JSON contains an invalid branch")
            branch = dict(raw_branch)
            variants = branch.get("variants", [])
            if not isinstance(variants, list):
                raise SystemExit("architecture branch variants must be an array")
            branch["variants"] = [
                variant_for_version(v, version, candidate["compatibility"], candidate["versionKey"])
                for v in variants if isinstance(v, dict)
            ]
            branch["key"] = f"{branch['key']}--{candidate['versionKey']}"
            result.append({
                **candidate,
                "sourceStrategy": str(status.get("strategy") or "partition"),
                "sourceKey": str(status.get("sourceKey") or candidate["versionKey"]),
                "branch": branch,
            })
    return result


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    cp = sub.add_parser("candidates")
    cp.add_argument("--graph", type=Path, required=True)
    cp.add_argument("--arches-json", default="")
    xp = sub.add_parser("collect")
    xp.add_argument("--graph", type=Path, required=True)
    xp.add_argument("--statuses-root", type=Path, required=True)
    xp.add_argument("--arches-json", required=True)
    args = ap.parse_args()

    graph = load(args.graph)
    if not isinstance(graph, dict) or graph.get("kind") != "source-acquisition-dag":
        raise SystemExit("invalid source acquisition DAG")
    if args.command == "candidates":
        arches = None
        if args.arches_json:
            arches = json.loads(args.arches_json)
            if not isinstance(arches, list):
                raise SystemExit("arches JSON must be an array")
        print(json.dumps(candidate_rows(graph, arches), separators=(",", ":")))
        return
    arches = json.loads(args.arches_json)
    if not isinstance(arches, list):
        raise SystemExit("arches JSON must be an array")
    print(json.dumps({"include": collect(graph, args.statuses_root, arches)}, separators=(",", ":")))


if __name__ == "__main__":
    main()
