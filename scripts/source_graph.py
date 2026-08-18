#!/usr/bin/env python3
"""Build a source-acquisition DAG from provider discovery observations.

The graph is intentionally metadata-only. It is created before any stock APK
payload is downloaded, so provider order cannot silently become source policy.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

SOURCE_RANK = {
    "direct": 600,
    "apkmirror": 500,
    "apkpure": 400,
    "archive": 300,
    "uptodown": 200,
    "aptoide": 100,
}
BROAD_CAPABLE = {"direct", "apkmirror", "apkpure", "archive", "uptodown"}


def norm_version(value: str) -> str:
    return value.strip().lstrip("v")


def requested_rows(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise SystemExit("arches must be a JSON array")
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in value:
        if isinstance(item, str):
            row = {"arch": item, "optional": False, "sourcePriority": "required"}
        elif isinstance(item, dict) and isinstance(item.get("arch"), str):
            row = dict(item)
            row.setdefault("optional", False)
            if "sourcePriority" not in row:
                row["sourcePriority"] = "desired" if row.get("optional") else "required"
        else:
            raise SystemExit("invalid architecture request")
        arch = row["arch"]
        if arch not in seen:
            rows.append(row)
            seen.add(arch)
    return rows


def version_sort_key(value: str) -> tuple:
    parts = re.split(r"[.-]", norm_version(value))
    return tuple((0, int(part)) if part.isdigit() else (1, part.lower()) for part in parts)


def sort_versions(values: list[str]) -> list[str]:
    return sorted(
        dict.fromkeys(norm_version(v) for v in values if str(v).strip()),
        key=version_sort_key,
        reverse=True,
    )


def provider_supports(provider: dict[str, Any], version: str) -> bool:
    advertised = {norm_version(str(v)) for v in provider.get("versions", []) if str(v).strip()}
    return norm_version(version) in advertised


def provider_sort_key(provider: dict[str, Any]) -> tuple[int, str]:
    source = str(provider.get("source", ""))
    return (-SOURCE_RANK.get(source, 0), source)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--observations", required=True)
    ap.add_argument("--versions-json", required=True)
    ap.add_argument("--arches-json", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--forward-probe-limit", type=int, default=0)
    ns = ap.parse_args()

    observations = json.loads(Path(ns.observations).read_text())
    allowed_raw = json.loads(ns.versions_json)
    arches = requested_rows(json.loads(ns.arches_json))
    if not isinstance(observations, list):
        raise SystemExit("observations must be an array")
    if not isinstance(allowed_raw, list) or not allowed_raw:
        raise SystemExit("versions must be a non-empty array")
    allowed: list[str] = []
    seen_versions: set[str] = set()
    for item in allowed_raw:
        if not isinstance(item, str) or not item.strip():
            raise SystemExit("versions must contain non-empty strings")
        value = norm_version(item)
        if value not in seen_versions:
            allowed.append(value)
            seen_versions.add(value)

    providers = [p for p in observations if isinstance(p, dict) and p.get("configured") is True]
    providers.sort(key=provider_sort_key)

    advertised_all = sort_versions([
        str(v)
        for provider in providers
        for v in provider.get("versions", [])
        if str(v).strip()
    ])
    forward_limit = max(0, ns.forward_probe_limit)
    newest_declared = max(allowed, key=version_sort_key)
    forward_versions = [
        version for version in advertised_all
        if version not in seen_versions and version_sort_key(version) > version_sort_key(newest_declared)
    ][:forward_limit]
    candidate_versions = [*forward_versions, *allowed]
    forward_set = set(forward_versions)

    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, str]] = []
    discovery_ids: list[str] = []
    for p in providers:
        source = str(p.get("source", ""))
        node_id = f"discover:{source}"
        discovery_ids.append(node_id)
        nodes.append({
            "id": node_id,
            "kind": "discovery",
            "source": source,
            "status": p.get("status", "unavailable"),
            "versions": p.get("versions", []),
            "versionOpaque": bool(p.get("versionOpaque")),
        })

    version_rows: list[dict[str, Any]] = []
    acquisition_order: list[dict[str, Any]] = []
    for version_index, version in enumerate(candidate_versions):
        supporting = [p for p in providers if p.get("status") == "ready" and provider_supports(p, version)]
        supporting.sort(key=provider_sort_key)
        probes = [p for p in providers if p not in supporting]
        probes.sort(key=provider_sort_key)
        version_id = f"version:{version}"
        compatibility = "forward-probe" if version in forward_set else "declared"
        nodes.append({
            "id": version_id,
            "kind": "version",
            "version": version,
            "plannerRank": version_index,
            "compatibility": compatibility,
            "advertisedBy": [p.get("source") for p in supporting],
            "providerCount": len(supporting),
        })
        for dep in discovery_ids:
            edges.append({"from": dep, "to": version_id})

        broad = [p for p in supporting if str(p.get("source")) in BROAD_CAPABLE]
        broad_probes = [p for p in probes if str(p.get("source")) in BROAD_CAPABLE]
        broad_sources = [str(p.get("source")) for p in [*broad, *broad_probes]]
        branch_sources = [str(p.get("source")) for p in [*supporting, *probes]]
        evidence = {str(p.get("source")): "advertised" for p in supporting}
        evidence.update({str(p.get("source")): "probe" for p in probes})
        attempt_ids: list[str] = []
        for source in broad_sources:
            attempt_id = f"acquire:{version}:broad:{source}"
            attempt_ids.append(attempt_id)
            nodes.append({"id": attempt_id, "kind": "acquire-broad", "version": version, "source": source, "evidence": evidence[source]})
            edges.append({"from": version_id, "to": attempt_id})
            acquisition_order.append({"version": version, "kind": "broad", "source": source})
        for row in arches:
            arch = row["arch"]
            for source in branch_sources:
                attempt_id = f"acquire:{version}:branch:{arch}:{source}"
                attempt_ids.append(attempt_id)
                nodes.append({
                    "id": attempt_id,
                    "kind": "acquire-branch",
                    "version": version,
                    "arch": arch,
                    "source": source,
                    "sourcePriority": row.get("sourcePriority", "required"),
                    "evidence": evidence[source],
                })
                edges.append({"from": version_id, "to": attempt_id})
        version_rows.append({
            "version": version,
            "plannerRank": version_index,
            "compatibility": compatibility,
            "advertisedBy": [p.get("source") for p in supporting],
            "providerCount": len(supporting),
            "broadSources": broad_sources,
            "branchSources": branch_sources,
            "advertisedSources": [str(p.get("source")) for p in supporting],
            "probeSources": [str(p.get("source")) for p in probes],
            "attemptIds": attempt_ids,
        })

    # Forward probes are real provider-advertised stock versions newer than the
    # patch bundle's declared boundary. They are kept separate from declared
    # compatibility so downstream patch jobs can fail them independently without
    # erasing known-good fallback nodes. Declared versions with provider evidence
    # still outrank blind exact-version probes.
    traversal = sorted(
        version_rows,
        key=lambda r: (
            0 if r["compatibility"] == "forward-probe" else (1 if r["providerCount"] else 2),
            r["plannerRank"],
        ),
    )
    graph = {
        "schemaVersion": 1,
        "kind": "source-acquisition-dag",
        "requestedArches": arches,
        "allowedVersions": allowed,
        "declaredVersions": allowed,
        "forwardProbeLimit": forward_limit,
        "forwardProbeVersions": forward_versions,
        "candidateVersions": candidate_versions,
        "discoveredVersions": advertised_all,
        "discoveredOutsideCompatibility": [v for v in advertised_all if v not in seen_versions],
        "providers": providers,
        "versions": version_rows,
        "versionTraversal": [r["version"] for r in traversal],
        "nodes": nodes,
        "edges": edges,
        "acquisitionOrder": acquisition_order,
    }
    Path(ns.output).write_text(json.dumps(graph, indent=2, sort_keys=True) + "\n")
    # Keep stdout machine-friendly for shell callers/tests.
    print(json.dumps({"versions": [r["version"] for r in traversal]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
