#!/usr/bin/env python3
"""Conservatively prune source runners when every pending branch has exact stock cache."""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from version_fanout import variant_for_version

API_VERSION = "2026-03-10"
SOURCE_PREFIX = "patched-kushion-source-v2-"
STOCK_PREFIX = "patched-kushion-stock-v2-"


def load_json_arg(value: str) -> Any:
    path = Path(value)
    if value.startswith("@"):
        return json.loads(Path(value[1:]).read_text())
    return json.loads(value)


def github_caches(repository: str, ref: str, token: str, api_url: str, key_prefix: str) -> list[dict[str, Any]]:
    if not repository or "/" not in repository:
        raise ValueError("repository must be OWNER/REPO")
    base = api_url.rstrip("/")
    owner, repo = repository.split("/", 1)
    page = 1
    rows: list[dict[str, Any]] = []
    while True:
        query = urllib.parse.urlencode({
            "ref": ref,
            "key": key_prefix,
            "per_page": 100,
            "page": page,
        })
        url = f"{base}/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(repo)}/actions/caches?{query}"
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "patched-kushion-cache-planner",
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.load(response)
        batch = payload.get("actions_caches", []) if isinstance(payload, dict) else []
        if not isinstance(batch, list):
            raise ValueError("GitHub cache response has no actions_caches array")
        rows.extend(row for row in batch if isinstance(row, dict))
        total = int(payload.get("total_count", len(rows))) if isinstance(payload, dict) else len(rows)
        if len(rows) >= total or len(batch) < 100:
            return rows
        page += 1


def pending_stock_keys(candidate: dict[str, Any], arches: list[Any], stock_impl_hash: str) -> list[dict[str, str]]:
    version = str(candidate["version"])
    compatibility = str(candidate.get("compatibility", "declared"))
    version_key = str(candidate["versionKey"])
    traversal = int(candidate.get("traversalIndex", 0))
    source_cache_key = str(candidate.get("sourceCacheKey", ""))
    if not source_cache_key or not stock_impl_hash:
        return []

    result: list[dict[str, str]] = []
    for raw_branch in arches:
        if not isinstance(raw_branch, dict):
            continue
        arch = str(raw_branch.get("arch", ""))
        variants = raw_branch.get("variants", [])
        if not arch or not isinstance(variants, list):
            continue
        expanded = [
            variant_for_version(v, version, compatibility, version_key, arch, traversal)
            for v in variants if isinstance(v, dict)
        ]
        if not expanded or all(isinstance(row.get("reuse"), dict) for row in expanded):
            continue
        base_branch_key = str(raw_branch.get("key", ""))
        stock_policy_hash = str(raw_branch.get("stockPolicyHash", ""))
        if not base_branch_key or not stock_policy_hash:
            return []
        branch_key = f"{base_branch_key}--{version_key}"
        key = f"{STOCK_PREFIX}{branch_key}-{source_cache_key}-{stock_policy_hash}-{stock_impl_hash}"
        result.append({"arch": arch, "branchKey": branch_key, "cacheKey": key})
    return result


def prune(
    candidates: list[Any], arches: list[Any], cache_rows: list[dict[str, Any]], *,
    source_impl_hash: str, stock_impl_hash: str, target_key: str, statuses_output: Path, report_output: Path | None,
) -> list[dict[str, Any]]:
    active = {
        str(row.get("key"))
        for row in cache_rows
        if isinstance(row.get("key"), str)
    }
    pending: list[dict[str, Any]] = []
    report: list[dict[str, Any]] = []
    for raw in candidates:
        if not isinstance(raw, dict):
            continue
        candidate = dict(raw)
        keys = pending_stock_keys(candidate, arches, stock_impl_hash)
        hits = [row for row in keys if row["cacheKey"] in active]
        all_stock_cached = bool(keys) and len(hits) == len(keys)
        source_key = f"{SOURCE_PREFIX}{target_key}-{candidate.get('sourceCacheKey', '')}-{source_impl_hash}"
        source_cached = len(keys) == 1 and source_impl_hash != "" and source_key in active
        strategy = "stock-cache" if all_stock_cached else ("source-cache" if source_cached else "")
        report.append({
            "version": candidate.get("version"),
            "versionKey": candidate.get("versionKey"),
            "pendingBranches": keys,
            "stockCacheHits": hits,
            "sourceCacheKey": source_key,
            "sourceCacheHit": source_cached,
            "pruned": bool(strategy),
            "strategy": strategy,
        })
        if not strategy:
            pending.append(candidate)
            continue
        version_key = str(candidate["versionKey"])
        output = statuses_output / version_key / "source-status.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        status = {
            "schemaVersion": 1,
            "target": "",
            "version": candidate["version"],
            "versionKey": version_key,
            "compatibility": candidate.get("compatibility", "declared"),
            "traversalIndex": candidate.get("traversalIndex", 0),
            "sourceKey": f"{target_key}--{version_key}",
            "strategy": strategy,
            "ready": True,
            "acquisitionOutcome": f"planner-{strategy}",
            "exitCode": "",
            "category": "",
            "reason": "",
            "diagnostics": {
                "stockCacheKeys": [row["cacheKey"] for row in keys],
                "sourceCacheKey": source_key if strategy == "source-cache" else "",
            },
        }
        output.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n")
    if report_output is not None:
        report_output.parent.mkdir(parents=True, exist_ok=True)
        report_output.write_text(json.dumps({"schemaVersion": 1, "candidates": report}, indent=2, sort_keys=True) + "\n")
    return pending


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates-json", required=True)
    ap.add_argument("--arches-json", required=True)
    ap.add_argument("--source-impl-hash", required=True)
    ap.add_argument("--stock-impl-hash", required=True)
    ap.add_argument("--target-key", required=True)
    ap.add_argument("--statuses-output", type=Path, required=True)
    ap.add_argument("--report-output", type=Path)
    ap.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--ref", default=os.environ.get("GITHUB_REF", ""))
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    ap.add_argument("--api-url", default=os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    ap.add_argument("--cache-list-file", type=Path)
    args = ap.parse_args()

    candidates = load_json_arg(args.candidates_json)
    arches = load_json_arg(args.arches_json)
    if not isinstance(candidates, list) or not isinstance(arches, list):
        raise SystemExit("candidates and arches must be arrays")

    if args.cache_list_file is not None:
        fixture = json.loads(args.cache_list_file.read_text())
        cache_rows = fixture.get("actions_caches", fixture) if isinstance(fixture, dict) else fixture
        if not isinstance(cache_rows, list):
            raise SystemExit("cache fixture must be an array or actions_caches object")
    else:
        if not args.repository or not args.ref:
            print("cache planner: repository/ref unavailable; keeping source runners", file=sys.stderr)
            print(json.dumps(candidates, separators=(",", ":")))
            return
        try:
            cache_rows = github_caches(args.repository, args.ref, args.token, args.api_url, STOCK_PREFIX)
            cache_rows.extend(github_caches(args.repository, args.ref, args.token, args.api_url, SOURCE_PREFIX))
        except (OSError, ValueError, urllib.error.HTTPError, urllib.error.URLError) as exc:
            print(f"cache planner: cache inventory unavailable ({exc}); keeping source runners", file=sys.stderr)
            print(json.dumps(candidates, separators=(",", ":")))
            return

    result = prune(
        candidates, arches, cache_rows,
        source_impl_hash=args.source_impl_hash,
        stock_impl_hash=args.stock_impl_hash,
        target_key=args.target_key,
        statuses_output=args.statuses_output,
        report_output=args.report_output,
    )
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
