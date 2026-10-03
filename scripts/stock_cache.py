#!/usr/bin/env python3
"""Size-aware stock policy and content-bound normalized handoffs (cache v3)."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import string
import time
from pathlib import Path, PurePosixPath
from typing import Any

from cache_handoff import load, sha256
from stock_bundle import BUILD_TO_ANDROID_ABI

POLICY = {"schemaVersion": 3, "maxPreparedBytes": 64 * 1024 * 1024,
          "largeInput": "normalized-source", "merger": "APKEditor"}
SOURCE_PREFIX = "patched-kushion-source-v3-"
STOCK_PREFIX = "patched-kushion-stock-v3-"


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest().upper()


def write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def safe_file(root: Path, name: str) -> Path:
    parts = PurePosixPath(name)
    if parts.is_absolute() or not parts.parts or any(p in ("..", ".") or "\\" in p or ":" in p for p in parts.parts):
        raise SystemExit(f"unsafe normalized payload path: {name}")
    path = root.joinpath(*parts.parts)
    if not path.resolve().is_relative_to(root.resolve()) or path.is_symlink() or not path.is_file():
        raise SystemExit(f"missing or unsafe normalized payload: {name}")
    return path


def verification(meta: dict[str, Any], security: dict[str, Any]) -> None:
    summary = meta.get("verification", {})
    cross = security.get("crossSource", {})
    if not isinstance(summary, dict) or not isinstance(cross, dict):
        raise SystemExit("invalid normalized source verification metadata")
    if (meta.get("signerVerified") is not True or security.get("securityValidated") is not True
            or summary.get("securityValidated") is not True
            or summary.get("comparisonSha256") != security.get("comparisonSha256")
            or summary.get("crossSource") != cross
            or cross.get("status") not in ("matched", "unavailable", "not-required", "disabled", "incomparable")):
        raise SystemExit("normalized source lacks successful signer/security/provenance verification")
    for field in ("comparisonSha256", "artifactSha256"):
        value = security.get(field, "")
        if not isinstance(value, str) or len(value) != 64 or any(c not in string.hexdigits for c in value):
            raise SystemExit(f"normalized source has invalid {field}")
    if not meta.get("sourceName") or meta.get("sourceName") != security.get("source"):
        raise SystemExit("normalized source security identity mismatch")


def source_files(root: Path, arch: str, *, branch_layout: bool = False) -> list[str]:
    if arch not in ("universal", *BUILD_TO_ANDROID_ABI):
        raise SystemExit("unsupported normalized source architecture")
    meta = load(root / "source.json")
    coverage = meta.get("coverage", {})
    if (meta.get("schemaVersion") != 2 or meta.get("status") != "ready"
            or not isinstance(coverage, dict) or coverage.get("missingRequired") != []
            or arch not in meta.get("availableBuildArches", [])):
        raise SystemExit("normalized source schema/status/coverage mismatch")
    names = ["source.json"]
    if meta.get("strategy") == "branches":
        prefix = "branch" if branch_layout else f"branches/{arch}"
        branch = load(root / prefix / "branch.json")
        if branch.get("available") is not True or branch.get("arch") != arch:
            raise SystemExit("normalized source branch axes mismatch")
        verification(branch, load(root / prefix / "source.security.json"))
        names += [f"{prefix}/branch.json", f"{prefix}/source.security.json"]
        if (root / prefix / "stock.apk").is_file():
            if sha256(root / prefix / "stock.apk") != str(load(root / prefix / "source.security.json").get("artifactSha256", "")).upper():
                raise SystemExit("normalized standalone security digest mismatch")
            names += [f"{prefix}/stock.apk"]
        else:
            splits = sorted((root / prefix / "splits").glob("*.apk"))
            if not splits:
                raise SystemExit("normalized source branch has no install set")
            names += [p.relative_to(root).as_posix() for p in splits]
            if (root / prefix / "selection.json").is_file():
                names += [f"{prefix}/selection.json"]
    elif meta.get("strategy") == "partition":
        verification(meta, load(root / "source.security.json"))
        partition = load(root / "partition.json")
        if partition.get("schemaVersion") != 1 or partition.get("availableBuildArches") != meta.get("availableBuildArches"):
            raise SystemExit("normalized source partition capabilities mismatch")
        names += ["partition.json", "source.security.json"]
        rows = partition.get("splits")
        if not isinstance(rows, list) or not rows:
            raise SystemExit("normalized source has no partition rows")
        for row in rows:
            if not isinstance(row, dict):
                raise SystemExit("invalid normalized source partition row")
            bucket = row.get("bucket")
            if bucket != "common" and bucket not in BUILD_TO_ANDROID_ABI:
                raise SystemExit("normalized source has invalid partition bucket")
            if row.get("abi") != (None if bucket == "common" else BUILD_TO_ANDROID_ABI[bucket]):
                raise SystemExit("normalized source partition ABI mismatch")
            if bucket != "common" and arch != "universal" and bucket != arch:
                continue
            output_name = str(row.get("output", ""))
            if PurePosixPath(output_name).name != output_name or not output_name.endswith(".apk"):
                raise SystemExit("normalized source has unsafe split output")
            partition_path = row.get("partitionPath")
            if partition_path is not None:
                if not isinstance(partition_path, str):
                    raise SystemExit("normalized source has invalid partition path")
                parts = PurePosixPath(partition_path)
                if (parts.is_absolute() or not parts.parts or parts.name != output_name
                        or any(part in ("", ".", "..") or "\\" in part or ":" in part for part in parts.parts)):
                    raise SystemExit("normalized source has unsafe partition path")
                expected_prefix = ("common",) if bucket == "common" else ("abi", str(bucket))
                if tuple(parts.parts[:len(expected_prefix)]) != expected_prefix:
                    raise SystemExit("normalized source partition path/bucket mismatch")
                name = parts.as_posix()
            else:
                name = f"common/{output_name}" if bucket == "common" else f"abi/{bucket}/{output_name}"
            path = safe_file(root, name)
            if sha256(path) != str(row.get("sha256", "")).upper() or path.stat().st_size != row.get("size"):
                raise SystemExit(f"normalized source partition digest/size mismatch: {name}")
            names.append(name)
    else:
        raise SystemExit("unsupported normalized source strategy")
    if len(set(names)) != len(names):
        raise SystemExit("duplicate normalized source files")
    return sorted(names)


def rows_for(root: Path, names: list[str]) -> list[dict[str, Any]]:
    return [{"path": name, "size": safe_file(root, name).stat().st_size,
             "sha256": sha256(safe_file(root, name))} for name in names]


def seal_source(root: Path, identity: str) -> None:
    meta = load(root / "source.json")
    names: set[str] = set()
    for arch in meta.get("availableBuildArches", []):
        names.update(source_files(root, arch))
    if not names or not identity:
        raise SystemExit("cannot seal empty source/identity")
    write(root / "source.cache.json", {"schemaVersion": 3, "sourceCacheKey": identity,
                                      "files": rows_for(root, sorted(names))})


def validate_source(root: Path, identity: str, arch: str = "", *, branch_layout: bool = False) -> list[dict[str, Any]]:
    ledger = load(root / "source.cache.json")
    if ledger.get("schemaVersion") != 3 or not identity or ledger.get("sourceCacheKey") != identity:
        raise SystemExit("normalized source cache identity mismatch")
    meta = load(root / "source.json")
    names: set[str] = set()
    for selected in ([arch] if arch else meta.get("availableBuildArches", [])):
        names.update(source_files(root, selected, branch_layout=branch_layout))
    rows = ledger.get("files", [])
    if not isinstance(rows, list) or not rows:
        raise SystemExit("invalid normalized source cache ledger")
    indexed: dict[str, Any] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            raise SystemExit("invalid normalized source cache ledger row")
        name = row["path"]
        if branch_layout and arch and name.startswith(f"branches/{arch}/"):
            name = "branch/" + name.split("/", 2)[2]
        if name in indexed:
            raise SystemExit("duplicate source cache ledger paths")
        indexed[name] = {**row, "path": name}
    actual = rows_for(root, sorted(names))
    if any(row != indexed.get(row["path"]) for row in actual):
        raise SystemExit("normalized source cache digest/metadata mismatch")
    # Extra APKs in a selected directory would otherwise enter APKEditor's merge.
    dirs = {str(PurePosixPath(n).parent) for n in names if n.endswith(".apk")}
    present = {p.relative_to(root).as_posix() for d in dirs for p in (root / d).glob("*.apk")}
    if present != {n for n in names if n.endswith(".apk")}:
        raise SystemExit("normalized source cache contains unlisted APKs")
    return actual


def prepare(root: Path, output: Path, target: str, version: str, arch: str, identity: str) -> bool:
    started = time.perf_counter()
    meta = load(root / "source.json")
    if (meta.get("target"), str(meta.get("version"))) != (target, version):
        raise SystemExit("normalized source target/version mismatch")
    rows = validate_source(root, identity, arch, branch_layout=True)
    size = sum(row["size"] for row in rows if row["path"].endswith(".apk"))
    deferred = size >= POLICY["maxPreparedBytes"]
    write(output / "cache-policy.json", {"policy": POLICY, "selectedSourceBytes": size,
                                         "representation": "normalized-source" if deferred else "prepared-apk"})
    if deferred:
        dest = output / "source"
        if dest.exists():
            if dest.is_symlink() or not dest.resolve().is_relative_to(output.resolve()):
                raise SystemExit("unsafe normalized output directory")
            shutil.rmtree(dest)
        for row in rows:
            path = dest / row["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(safe_file(root, row["path"]), path)
        shutil.copy2(root / "source.cache.json", dest / "source.cache.json")
        contract = {"schemaVersion": 2, "representation": "normalized-source", "target": target,
                    "version": version, "arch": arch, "packageName": meta["packageName"],
                    "sourceCacheKey": identity, "policy": POLICY, "files": rows}
        contract["inputSha256"] = digest(contract)
        write(output / "stock.json", contract)
    write(output / "preparation.json", {"selectedSourceBytes": size,
                                        "preparationSeconds": time.perf_counter() - started,
                                        "mergeDeferred": deferred, "mergeCount": 0})
    return deferred


def validate_normalized(root: Path, target: str, version: str, arch: str, source_key: str = "") -> str:
    meta = load(root / "stock.json")
    if (meta.get("schemaVersion"), meta.get("representation"), meta.get("policy")) != (2, "normalized-source", POLICY):
        raise SystemExit("normalized stock schema/policy mismatch")
    if (meta.get("target"), meta.get("version"), meta.get("arch")) != (target, version, arch):
        raise SystemExit("normalized stock axes mismatch")
    if source_key and meta.get("sourceCacheKey") != source_key:
        raise SystemExit("normalized stock source policy mismatch")
    expected = meta.get("inputSha256")
    if expected != digest({k: v for k, v in meta.items() if k != "inputSha256"}):
        raise SystemExit("normalized stock input identity mismatch")
    rows = validate_source(root / "source", meta.get("sourceCacheKey", ""), arch, branch_layout=True)
    source = load(root / "source/source.json")
    if rows != meta.get("files") or (source.get("target"), source.get("version"), source.get("packageName")) != (target, version, meta.get("packageName")):
        raise SystemExit("normalized stock source contract mismatch")
    return str(expected)


def cacheable(root: Path) -> bool:
    if (root / "stock.json").is_file() and load(root / "stock.json").get("schemaVersion") == 2:
        return False
    return sum(p.stat().st_size for p in root.rglob("*") if p.is_file()) < POLICY["maxPreparedBytes"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("seal-source", "source", "prepare", "identity", "cacheable"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--source-key", default="")
    parser.add_argument("--target", default="")
    parser.add_argument("--version", default="")
    parser.add_argument("--arch", default="")
    args = parser.parse_args()
    if args.command == "seal-source":
        seal_source(args.root, args.source_key)
    elif args.command == "source":
        validate_source(args.root, args.source_key)
    elif args.command == "prepare":
        if args.output is None:
            parser.error("prepare requires --output")
        print(str(prepare(args.root, args.output, args.target, args.version, args.arch, args.source_key)).lower())
    elif args.command == "cacheable":
        print(str(cacheable(args.root)).lower())
    else:
        meta = load(args.root / "stock.json")
        if meta.get("schemaVersion") == 2:
            print(validate_normalized(args.root, args.target, args.version, args.arch, args.source_key))
        else:
            from cache_handoff import validate_stock
            validate_stock(args.root, args.target, args.version, args.arch)
            print(sha256(args.root / "stock.apk"))


if __name__ == "__main__":
    main()
