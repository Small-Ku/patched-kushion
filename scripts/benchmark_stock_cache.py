#!/usr/bin/env python3
"""Compare local zstd archive write/restore costs for v2 stock and v3 source.

This approximates Actions' tar/zstd transport on a local disk, not network or
hosted cache service time. Run benchmark-stock-cache.sh to establish real signer
and fingerprint gates plus APKEditor materialization timings first.
"""
import argparse
import json
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

from cache_handoff import load, sha256
from stock_cache import POLICY


def transport(root: Path, name: str, files: list[str], iterations: int) -> dict:
    archive = root / f"{name}.tar.zst"
    saves, restores = [], []
    for iteration in range(iterations):
        start = time.perf_counter()
        subprocess.run(["tar", "--zstd", "-cf", str(archive), "-C", str(root), *files], check=True)
        saves.append(time.perf_counter() - start)
        dest = root / f"restore-{name}-{iteration}"
        dest.mkdir()
        start = time.perf_counter()
        subprocess.run(["tar", "--zstd", "-xf", str(archive), "-C", str(dest)], check=True)
        restores.append(time.perf_counter() - start)
        for name in files:
            src = root / name
            for original in ([src] if src.is_file() else src.rglob("*")):
                if original.is_file() and sha256(original) != sha256(dest / original.relative_to(root)):
                    raise SystemExit("benchmark archive round trip changed payload bytes")
        shutil.rmtree(dest)
    return {"archiveBytes": archive.stat().st_size, "saveSeconds": saves, "restoreSeconds": restores,
            "medianSaveSeconds": statistics.median(saves), "medianRestoreSeconds": statistics.median(restores)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--apkeditor", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=3)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("iterations must be positive")
    rows = []
    for arch in ("universal", "arm64-v8a"):
        root = args.root / arch
        before = transport(root, "v2-stock", ["prepared"], args.iterations)
        after = transport(root / "normalized", "v3-selected-source", ["source", "stock.json"], args.iterations)
        rows.append({"arch": arch, "v2PreparedStock": before, "v3SelectedSource": after,
                     "v3AdditionalPreparedStockCacheBytes": 0,
                     "preparation": load(root / "normalized/preparation.json"),
                     "materialization": load(root / "diagnostics/materialization.json")})
    report = {"schemaVersion": 1, "platform": platform.platform(), "policy": POLICY,
              "bundleSha256": sha256(args.bundle), "apkeditorSha256": sha256(args.apkeditor),
              "transport": "local tar --zstd; digest-checked round trips; not hosted/network timing",
              "iterations": args.iterations, "architectures": rows}
    path = args.root / "benchmark.json"
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(path)


if __name__ == "__main__":
    main()
