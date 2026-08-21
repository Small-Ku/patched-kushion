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
    for traversal_index, value in enumerate(graph.get("versionTraversal", [])):
        version = str(value)
        row = rows_by_version.get(version, {})
        candidate: dict[str, Any] = {
            "version": version,
            "versionKey": version_key(version),
            "compatibility": str(row.get("compatibility", "declared")),
            "traversalIndex": traversal_index,
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
                        expanded.append(variant_for_version(variant, version, candidate["compatibility"], candidate["versionKey"], str(raw_branch.get("arch", "")), traversal_index))
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


def variant_for_version(variant: dict[str, Any], version: str, compatibility: str, key: str, arch: str, traversal_index: int = 0) -> dict[str, Any]:
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
            "arch": arch,
            "mode": variant["mode"],
        })

    reuse_index = variant.get("reuseByInputId")
    reuse = reuse_index.get(input_id) if isinstance(reuse_index, dict) else None
    out = dict(variant)
    out["inputId"] = input_id
    out["selectedVersion"] = version
    out["compatibility"] = compatibility
    out["traversalIndex"] = traversal_index
    out["resultKey"] = f"{variant['key']}--{key}"
    out["reuse"] = reuse if isinstance(reuse, dict) else None
    return out


def collect(graph: dict[str, Any], statuses_root: Path, arches: list[Any], *, prune_reuse: bool = False, target: str = "") -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    args_target = target
    statuses: dict[str, dict[str, Any]] = {}
    for path in statuses_root.rglob("source-status.json"):
        row = load(path)
        if not isinstance(row, dict) or not row.get("version"):
            continue
        statuses[str(row["version"])] = row

    candidates = {row["version"]: row for row in candidate_rows(graph, arches)}
    result: list[dict[str, Any]] = []
    reused: list[dict[str, Any]] = []
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
            expanded = [
                variant_for_version(v, version, candidate["compatibility"], candidate["versionKey"], str(branch["arch"]), int(candidate.get("traversalIndex", 0)))
                for v in variants if isinstance(v, dict)
            ]
            branch["key"] = f"{branch['key']}--{candidate['versionKey']}"
            if prune_reuse:
                pending = []
                for variant in expanded:
                    if isinstance(variant.get("reuse"), dict):
                        reused.append({
                            "target": args_target,
                            "version": version,
                            "arch": str(branch["arch"]),
                            "variant": variant,
                        })
                    else:
                        pending.append(variant)
                if not pending:
                    continue
                branch["variants"] = pending
            else:
                branch["variants"] = expanded
            result.append({
                **candidate,
                "sourceStrategy": str(status.get("strategy") or "partition"),
                "sourceKey": str(status.get("sourceKey") or candidate["versionKey"]),
                "branch": branch,
            })
    return result, reused


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    cp = sub.add_parser("candidates")
    cp.add_argument("--graph", type=Path, required=True)
    cp.add_argument("--arches-json", default="")
    cp.add_argument("--prune-reuse", action="store_true")
    cp.add_argument("--reuse-statuses-output", type=Path)
    cp.add_argument("--target-key", default="")
    xp = sub.add_parser("collect")
    xp.add_argument("--graph", type=Path, required=True)
    xp.add_argument("--statuses-root", type=Path, required=True)
    xp.add_argument("--arches-json", required=True)
    xp.add_argument("--prune-reuse", action="store_true")
    xp.add_argument("--reuse-output", type=Path)
    xp.add_argument("--target", default="")
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
        rows = candidate_rows(graph, arches)
        if args.prune_reuse:
            if args.reuse_statuses_output is None or not args.target_key:
                raise SystemExit("--prune-reuse requires --reuse-statuses-output and --target-key")
            pending = []
            for row in rows:
                if row.get("allReusable") is not True:
                    pending.append(row)
                    continue
                output = args.reuse_statuses_output / str(row["versionKey"]) / "source-status.json"
                output.parent.mkdir(parents=True, exist_ok=True)
                status = {
                    "schemaVersion": 1,
                    "target": "",
                    "version": row["version"],
                    "versionKey": row["versionKey"],
                    "compatibility": row["compatibility"],
                    "traversalIndex": row["traversalIndex"],
                    "sourceKey": f"{args.target_key}--{row['versionKey']}",
                    "strategy": "reuse",
                    "ready": True,
                    "acquisitionOutcome": "reused",
                    "exitCode": "",
                    "category": "",
                    "reason": "",
                    "diagnostics": {},
                }
                output.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n")
            rows = pending
        print(json.dumps(rows, separators=(",", ":")))
        return
    arches = json.loads(args.arches_json)
    if not isinstance(arches, list):
        raise SystemExit("arches JSON must be an array")
    included, reused = collect(graph, args.statuses_root, arches, prune_reuse=args.prune_reuse, target=args.target)
    if args.reuse_output is not None:
        args.reuse_output.parent.mkdir(parents=True, exist_ok=True)
        args.reuse_output.write_text(json.dumps({"schemaVersion": 1, "reused": reused}, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"include": included}, separators=(",", ":")))


if __name__ == "__main__":
    main()
