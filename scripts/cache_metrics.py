#!/usr/bin/env python3
"""Record cache-action wall time and logical payload bytes without toolchain setup.

Archive/network bytes remain in the Actions cache logs; logical bytes are measured
from the restored/requested directory and are deliberately labelled separately.
"""
import argparse
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def archive_bytes(key: str) -> tuple[int | None, str]:
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not key or not repository:
        return None, "no-cache-key-or-repository"
    query = urllib.parse.urlencode({"key": key, "ref": os.environ.get("GITHUB_REF", ""), "per_page": 100})
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    try:
        request = urllib.request.Request(f"{base}/repos/{repository}/actions/caches?{query}", headers=headers)
        with urllib.request.urlopen(request, timeout=10) as response:
            rows = json.load(response).get("actions_caches", [])
        matches = [row for row in rows if row.get("key") == key]
        if matches:
            return int(matches[0]["size_in_bytes"]), "observed-cache-inventory"
        return None, "not-visible-in-cache-inventory"
    except (OSError, ValueError, KeyError, urllib.error.URLError):
        return None, "cache-inventory-unavailable"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("start", "record", "summary"))
    parser.add_argument("--clock", type=Path)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--stage", default="")
    parser.add_argument("--operation", choices=("restore", "save"))
    parser.add_argument("--hit", default="")
    parser.add_argument("--key", default="")
    args = parser.parse_args()
    if args.command == "summary":
        values = {p.stem: json.loads(p.read_text()) for name in
                  ("cache-policy.json", "preparation.json", "materialization.json")
                  if (p := args.root / name).is_file()}
        if values:
            text = "\nCache/materialization diagnostics (bytes are logical payload bytes):\n\n```json\n" + json.dumps(values, indent=2, sort_keys=True) + "\n```\n"
            print(text)
            if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
                with open(summary, "a") as handle:
                    handle.write(text)
        return
    if args.clock is None:
        parser.error("start/record requires --clock")
    if args.command == "start":
        args.clock.write_text(str(time.monotonic_ns()))
        return
    elapsed = (time.monotonic_ns() - int(args.clock.read_text())) / 1e9
    size = sum(p.stat().st_size for p in args.root.rglob("*") if p.is_file())
    event = {"stage": args.stage, "operation": args.operation, "actionSeconds": elapsed,
             "logicalBytes": size, "cacheHit": args.hit == "true" if args.operation == "restore" else None,
             "byteSemantics": "restored-directory" if args.operation == "restore" else "save-request-directory"}
    compressed, observation = archive_bytes(args.key)
    event.update(cacheKey=args.key, archiveBytes=compressed, archiveObservation=observation)
    if args.operation == "restore" and args.hit == "true":
        # A cached miss's timing is historical evidence, not work done this run.
        (args.root / "materialization.json").write_text(json.dumps(
            {"schemaVersion": 1, "mergeCount": 0, "materializationSeconds": 0, "cacheHit": True}) + "\n")
        if (args.root / "preparation.json").exists():
            prior = json.loads((args.root / "preparation.json").read_text())
            prior["preparationSeconds"] = 0
            prior["cacheHit"] = True
            (args.root / "preparation.json").write_text(json.dumps(prior) + "\n")
    report = json.loads(args.report.read_text()) if args.report.exists() else {"schemaVersion": 1, "events": []}
    report["events"].append(event)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(f"\nCache {args.stage} {args.operation}: {size:,} logical bytes; "
                         f"{elapsed:.3f} s action wall time; {event['byteSemantics']}; "
                         f"hit={event['cacheHit']}; archive bytes={compressed} ({observation}). "
                         "Transfer details are in the cache action log.\n")


if __name__ == "__main__":
    main()
