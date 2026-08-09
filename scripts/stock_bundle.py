#!/usr/bin/env python3
"""Inspect and select APK splits from APKM, APKS, and XAPK containers.

The selector keeps the base/master APK, the requested ABI split, and every
non-ABI split. This preserves language, density, feature, and other config
splits while removing CPU payloads for other architectures.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

BUILD_TO_ANDROID_ABI = {
    "arm64-v8a": "arm64-v8a",
    "arm-v7a": "armeabi-v7a",
    "x86": "x86",
    "x86_64": "x86_64",
}
ANDROID_ABIS = tuple(BUILD_TO_ANDROID_ABI.values())


class BundleError(RuntimeError):
    pass


@dataclass(frozen=True)
class Split:
    member: str
    abi: str | None
    lib_abis: tuple[str, ...]


def _abi_from_name(member: str) -> str | None:
    name = PurePosixPath(member).name.lower()
    normalized = re.sub(r"[.-]", "_", name)
    patterns = (
        ("arm64-v8a", ("arm64_v8a",)),
        ("armeabi-v7a", ("armeabi_v7a", "arm_v7a")),
        ("x86_64", ("x86_64",)),
        ("x86", ("x86",)),
    )
    for abi, tokens in patterns:
        if any(re.search(rf"(?:^|_){re.escape(token)}(?:_|\.apk$)", normalized) for token in tokens):
            return abi
    return None


def _lib_abis(zf: zipfile.ZipFile, member: str) -> tuple[str, ...]:
    try:
        payload = zf.read(member)
    except KeyError as exc:
        raise BundleError(f"bundle member disappeared: {member}") from exc
    from io import BytesIO

    try:
        with zipfile.ZipFile(BytesIO(payload)) as apk:
            found = {
                parts[1]
                for name in apk.namelist()
                if name.startswith("lib/")
                for parts in [name.split("/", 2)]
                if len(parts) >= 3 and parts[1] in ANDROID_ABIS
            }
    except zipfile.BadZipFile as exc:
        raise BundleError(f"APK split is not a ZIP archive: {member}") from exc
    return tuple(abi for abi in ANDROID_ABIS if abi in found)


def _candidate_members(zf: zipfile.ZipFile) -> list[str]:
    members = [name for name in zf.namelist() if not name.endswith("/") and name.lower().endswith(".apk")]
    if not members:
        raise BundleError("container has no APK members")

    # bundletool .apks archives can contain both a split set and large standalone
    # alternatives. Use the split set when it exists; APKEditor should receive one
    # coherent install set, not both representations.
    split_members = [name for name in members if PurePosixPath(name).parts[:1] == ("splits",)]
    if split_members:
        return split_members

    ignored_dirs = {"standalones", "standalone", "instant", "instantapps"}
    filtered = [
        name for name in members
        if not any(part.lower() in ignored_dirs for part in PurePosixPath(name).parts[:-1])
    ]
    return filtered or members


def inspect_bundle(path: Path) -> list[Split]:
    try:
        with zipfile.ZipFile(path) as zf:
            result: list[Split] = []
            for member in _candidate_members(zf):
                libs = _lib_abis(zf, member)
                name_abi = _abi_from_name(member)
                abi = name_abi
                if abi is None and len(libs) == 1:
                    abi = libs[0]
                result.append(Split(member=member, abi=abi, lib_abis=libs))
            return result
    except FileNotFoundError as exc:
        raise BundleError(f"bundle does not exist: {path}") from exc
    except zipfile.BadZipFile as exc:
        raise BundleError(f"not a ZIP-based APK bundle: {path}") from exc


def select_splits(splits: list[Split], arch: str) -> list[Split]:
    if arch == "all":
        return list(splits)
    try:
        requested = BUILD_TO_ANDROID_ABI[arch]
    except KeyError as exc:
        raise BundleError(f"unsupported build architecture: {arch}") from exc

    abi_splits = [split for split in splits if split.abi in ANDROID_ABIS]
    selected = [split for split in splits if split.abi is None or split.abi == requested]
    if abi_splits and not any(split.abi == requested for split in abi_splits):
        available = sorted({split.abi for split in abi_splits if split.abi})
        raise BundleError(
            f"bundle has ABI splits ({', '.join(available)}) but none for {requested}"
        )
    if not selected:
        raise BundleError("split selection produced an empty install set")
    return selected


def safe_output_name(member: str, used: set[str]) -> str:
    base = PurePosixPath(member).name
    if base not in used:
        used.add(base)
        return base
    stem = Path(base).stem
    suffix = Path(base).suffix
    parent = "_".join(PurePosixPath(member).parts[:-1]) or "split"
    parent = re.sub(r"[^A-Za-z0-9_.-]+", "_", parent)
    candidate = f"{parent}_{stem}{suffix}"
    index = 2
    while candidate in used:
        candidate = f"{parent}_{stem}_{index}{suffix}"
        index += 1
    used.add(candidate)
    return candidate


def extract_selected(bundle: Path, arch: str, output_dir: Path) -> dict[str, object]:
    splits = inspect_bundle(bundle)
    selected = select_splits(splits, arch)
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    used: set[str] = set()
    output_rows: list[dict[str, object]] = []
    with zipfile.ZipFile(bundle) as zf:
        for split in selected:
            output_name = safe_output_name(split.member, used)
            target = output_dir / output_name
            with zf.open(split.member) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            output_rows.append(
                {
                    "member": split.member,
                    "output": output_name,
                    "abi": split.abi,
                    "libAbis": list(split.lib_abis),
                }
            )
    return {
        "schemaVersion": 1,
        "bundle": str(bundle),
        "arch": arch,
        "androidAbi": BUILD_TO_ANDROID_ABI.get(arch, "all"),
        "availableAbis": sorted({split.abi for split in splits if split.abi}),
        "selected": output_rows,
    }


def inspect_payload(path: Path) -> dict[str, object]:
    splits = inspect_bundle(path)
    return {
        "schemaVersion": 1,
        "bundle": str(path),
        "availableAbis": sorted({split.abi for split in splits if split.abi}),
        "splits": [
            {"member": split.member, "abi": split.abi, "libAbis": list(split.lib_abis)}
            for split in splits
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("inspect")
    inspect.add_argument("--bundle", type=Path, required=True)
    select = sub.add_parser("select")
    select.add_argument("--bundle", type=Path, required=True)
    select.add_argument("--arch", choices=["all", *BUILD_TO_ANDROID_ABI], required=True)
    select.add_argument("--output-dir", type=Path, required=True)
    select.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            payload = inspect_payload(args.bundle)
        else:
            payload = extract_selected(args.bundle, args.arch, args.output_dir)
            if args.manifest:
                args.manifest.parent.mkdir(parents=True, exist_ok=True)
                args.manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(json.dumps(payload, separators=(",", ":")))
        return 0
    except BundleError as exc:
        print(f"stock bundle error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
