#!/usr/bin/env python3
"""Inspect and select APK splits from APKM, APKS, and XAPK containers.

Inventory categories describe preserved APK members; they do not imply that
individual categories are independently publishable. Acquisition preserves the
base/master APK, the requested ABI split, and every non-ABI split. Standalone
composition selects required members from that inventory before APKEditor merges.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from stock_fingerprint import run_aapt2

BUILD_TO_ANDROID_ABI = {
    "arm64-v8a": "arm64-v8a",
    "arm-v7a": "armeabi-v7a",
    "x86": "x86",
    "x86_64": "x86_64",
}
ANDROID_ABIS = tuple(BUILD_TO_ANDROID_ABI.values())
ANDROID_ABI_TO_BUILD = {value: key for key, value in BUILD_TO_ANDROID_ABI.items()}


class BundleError(RuntimeError):
    pass


@dataclass(frozen=True)
class Split:
    member: str
    abi: str | None
    lib_abis: tuple[str, ...]
    dimension: str
    selector: str | None


def _classify_split(member: str, abi: str | None) -> tuple[str, str | None]:
    """Classify a split conservatively from its path and conventional split ID.

    Store containers do not share a metadata index. Recognized base names and
    ABI library contents are strong signals; density, locale, and feature
    selectors use documented Android/bundletool filename conventions. Anything
    else remains ``other`` and is still preserved.
    """
    path = PurePosixPath(member)
    name = path.stem.lower()
    normalized = re.sub(r"[.-]", "_", name)
    if name in {"base", "base_master", "base-master", "master", "universal"}:
        return "core", "base" if name != "universal" else "universal"
    if abi is not None:
        return "abi", abi

    # Config names seen in APKM/XAPK and bundletool APKS. Keep selectors in
    # their source spelling except for canonical ABI values.
    token = normalized
    token = re.sub(r"^(?:split_)?config_", "", token)
    token = re.sub(r"^base_", "", token)
    token = re.sub(r"^config_", "", token)
    density = {"ldpi", "mdpi", "tvdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi", "nodpi", "anydpi"}
    if token in density or re.fullmatch(r"\d+dpi", token):
        return "density", token
    if re.fullmatch(r"\d+_\d+dpi", token):
        return "density", token.replace("_", "-")

    # BCP-47 split IDs are commonly encoded as b+zh+Hans+CN; legacy language
    # IDs are two/three-letter language tags with optional region/script.
    locale_token = token[2:] if token.startswith("b+") else token
    locale_pattern = r"(?:[a-z]{2,3})(?:\+[a-z0-9]{2,8})*"
    if re.fullmatch(locale_pattern, locale_token):
        return "locale", locale_token.replace("+", "-")

    feature_dirs = {part.lower() for part in path.parts[:-1]}
    if feature_dirs.intersection({"features", "feature", "modules"}):
        parent = path.parts[-2].lower()
        selector = path.stem if parent in {"features", "modules"} else path.parts[-2]
        return "feature", selector
    feature_match = re.match(r"^(?:split_)?feature[_+.-](.+)$", name)
    if feature_match:
        return "feature", feature_match.group(1)
    return "other", None


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
                basename = PurePosixPath(member).name.lower()
                split_like = (
                    basename.startswith(("config.", "config_", "split_"))
                    or "-config." in basename
                    or "_config." in basename
                )
                # Native libraries are a useful fallback signal for an obscurely
                # named config split. Do not infer the ABI of a base/master APK
                # from its libraries: a base must stay in every selected set and
                # unwanted embedded libraries are stripped later from the merged APK.
                if abi is None and split_like and len(libs) == 1:
                    abi = libs[0]
                dimension, selector = _classify_split(member, abi)
                result.append(
                    Split(
                        member=member,
                        abi=abi,
                        lib_abis=libs,
                        dimension=dimension,
                        selector=selector,
                    )
                )
            return result
    except FileNotFoundError as exc:
        raise BundleError(f"bundle does not exist: {path}") from exc
    except zipfile.BadZipFile as exc:
        raise BundleError(f"not a ZIP-based APK bundle: {path}") from exc


def derivable_build_arches(splits: list[Split]) -> list[str]:
    """Return distribution branches that can be derived without relabeling an ABI.

    Explicit ABI config splits preserve partition boundaries. A container with one
    such ABI is therefore single-ABI, not universal. If no ABI config split exists,
    native libraries are only a capability hint for the whole flattened payload:
    no native libraries are noarch/universal, one ABI is single-ABI, and several
    ABIs form a universal-only fat payload because there are no split boundaries.
    """
    explicit = [
        build_arch
        for build_arch, android_abi in BUILD_TO_ANDROID_ABI.items()
        if any(split.abi == android_abi for split in splits)
    ]
    if explicit:
        return (["universal"] if len(explicit) >= 2 else []) + explicit

    embedded = [
        build_arch
        for build_arch, android_abi in BUILD_TO_ANDROID_ABI.items()
        if any(android_abi in split.lib_abis for split in splits)
    ]
    if not embedded:
        return ["universal"]
    if len(embedded) == 1:
        return embedded
    return ["universal"]


def select_splits(splits: list[Split], arch: str) -> list[Split]:
    available_build_arches = derivable_build_arches(splits)
    if arch not in available_build_arches:
        raise BundleError(
            f"bundle can derive {', '.join(available_build_arches) or 'no build architectures'}, "
            f"not {arch}"
        )
    if arch == "universal":
        return list(splits)
    try:
        requested = BUILD_TO_ANDROID_ABI[arch]
    except KeyError as exc:
        raise BundleError(f"unsupported build architecture: {arch}") from exc

    abi_splits = [split for split in splits if split.abi in ANDROID_ABIS]
    if abi_splits:
        selected = [split for split in splits if split.abi is None or split.abi == requested]
    else:
        # No explicit config ABI boundaries exist. derivable_build_arches() only
        # admits a concrete branch here when the whole container is single-ABI.
        selected = list(splits)
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


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def partition_bundle(bundle: Path, output_root: Path) -> dict[str, object]:
    """Extract every candidate split into a dimension-aware inventory."""
    splits = inspect_bundle(bundle)
    if output_root.exists():
        shutil.rmtree(output_root)
    common_dir = output_root / "common"
    abi_root = output_root / "abi"
    common_dir.mkdir(parents=True)
    for build_arch in BUILD_TO_ANDROID_ABI:
        (abi_root / build_arch).mkdir(parents=True)

    used_by_bucket: dict[str, set[str]] = {"common": set()}
    used_by_bucket.update({build_arch: set() for build_arch in BUILD_TO_ANDROID_ABI})
    rows: list[dict[str, object]] = []
    totals: dict[str, dict[str, int]] = {}
    with zipfile.ZipFile(bundle) as zf:
        for split in splits:
            build_arch = ANDROID_ABI_TO_BUILD.get(split.abi) if split.abi else None
            bucket = build_arch or "common"
            category_dir = common_dir / split.dimension
            if split.dimension == "abi":
                category_dir = abi_root / str(build_arch)
            elif split.dimension in {"density", "locale"}:
                category_dir = category_dir / (split.selector or "unknown")
            target_dir = category_dir
            target_dir.mkdir(parents=True, exist_ok=True)
            output_name = safe_output_name(split.member, used_by_bucket[bucket])
            target = target_dir / output_name
            info = zf.getinfo(split.member)
            with zf.open(split.member) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            apk_compressed = apk_uncompressed = None
            try:
                with zipfile.ZipFile(target) as apk:
                    apk_compressed = sum(entry.compress_size for entry in apk.infolist())
                    apk_uncompressed = sum(entry.file_size for entry in apk.infolist())
            except zipfile.BadZipFile:
                pass
            rows.append({
                "member": split.member,
                "output": output_name,
                "bucket": bucket,
                "dimension": split.dimension,
                "selector": split.selector,
                "partitionPath": target.relative_to(output_root).as_posix(),
                "abi": split.abi,
                "libAbis": list(split.lib_abis),
                "size": target.stat().st_size,
                "containerCompressedSize": info.compress_size,
                "containerUncompressedSize": info.file_size,
                "apkEntryCompressedBytes": apk_compressed,
                "apkEntryUncompressedBytes": apk_uncompressed,
                "sha256": _sha256(target),
            })
            total = totals.setdefault(
                split.dimension,
                {
                    "splitCount": 0,
                    "apkBytes": 0,
                    "containerCompressedBytes": 0,
                    "containerUncompressedBytes": 0,
                },
            )
            total["splitCount"] += 1
            total["apkBytes"] += target.stat().st_size
            total["containerCompressedBytes"] += info.compress_size
            total["containerUncompressedBytes"] += info.file_size

    available_build_arches = derivable_build_arches(splits)
    size_estimates: dict[str, dict[str, object]] = {}
    for build_arch in available_build_arches:
        requested_abi = BUILD_TO_ANDROID_ABI.get(build_arch)
        if build_arch == "universal":
            arch_selected = rows
        else:
            arch_selected = [
                r for r in rows
                if r.get("dimension") != "abi" or r.get("abi") == requested_abi
            ]
        arch_bytes = sum(int(r["size"]) for r in arch_selected)
        size_estimates[build_arch] = {
            "estimatedStandaloneBytes": arch_bytes,
            "sizeEstimateBasis": "preserve-split-set",
            "sizeEstimateEvidence": {
                "topology": "split-partition",
                "canBuildRequestedArch": True,
                "selectedSplitCount": len(arch_selected),
                "totalSplitCount": len(rows),
                "selectedMemberBytes": arch_bytes,
                "totalMemberBytes": sum(int(r["size"]) for r in rows),
                "minimalProven": False,
                "minimalSavingsBytes": 0,
                "omittedSplitCount": 0,
            },
        }
    payload = {
        "schemaVersion": 1,
        "bundle": str(bundle),
        "availableAbis": sorted({split.abi for split in splits if split.abi}),
        "availableBuildArches": available_build_arches,
        "byteTotalsByDimension": totals,
        "splits": rows,
        "sizeEstimates": size_estimates,
    }
    (output_root / "partition.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    for build_arch in BUILD_TO_ANDROID_ABI:
        availability = {
            "schemaVersion": 1,
            "arch": build_arch,
            "available": build_arch in available_build_arches,
        }
        (abi_root / build_arch / "availability.json").write_text(
            json.dumps(availability, sort_keys=True) + "\n"
        )
    return payload


def _verify_partition_file(root: Path, row: dict[str, object]) -> Path:
    if row.get("partitionPath"):
        source = root / str(row["partitionPath"])
    else:  # Read pre-dimension schema manifests during cache/workflow transition.
        bucket = str(row["bucket"])
        output = str(row["output"])
        source = root / ("common" if bucket == "common" else f"abi/{bucket}") / output
    if not source.is_file():
        raise BundleError(f"partition file is missing: {source}")
    expected = str(row.get("sha256", "")).upper()
    if not expected or _sha256(source) != expected:
        raise BundleError(f"partition digest mismatch: {source}")
    return source


def materialize_partition(root: Path, arch: str, output_dir: Path) -> dict[str, object]:
    manifest_path = root / "partition.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except FileNotFoundError as exc:
        raise BundleError(f"partition manifest does not exist: {manifest_path}") from exc
    except json.JSONDecodeError as exc:
        raise BundleError(f"invalid partition manifest: {manifest_path}") from exc
    rows = manifest.get("splits")
    if not isinstance(rows, list):
        raise BundleError("partition manifest has no split list")

    requested_abi = BUILD_TO_ANDROID_ABI.get(arch)
    available_build_arches = manifest.get("availableBuildArches", [])
    if not isinstance(available_build_arches, list) or not all(
        isinstance(value, str) for value in available_build_arches
    ):
        raise BundleError("partition manifest has invalid availableBuildArches")
    if arch not in available_build_arches:
        raise BundleError(
            f"partition can derive {', '.join(available_build_arches) or 'no build architectures'}, "
            f"not {arch}"
        )
    if arch != "universal" and requested_abi is None:
        raise BundleError(f"unsupported build architecture: {arch}")

    selected = [
        row for row in rows
        if isinstance(row, dict)
        and (
            row.get("dimension") != "abi"
            and not (row.get("dimension") is None and row.get("bucket") != "common")
            or arch == "universal"
            or row.get("abi") == requested_abi
        )
    ]
    if not selected:
        raise BundleError("partition selection produced an empty install set")
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    used: set[str] = set()
    output_rows: list[dict[str, object]] = []
    for row in selected:
        source = _verify_partition_file(root, row)
        output_name = safe_output_name(str(row["member"]), used)
        target = output_dir / output_name
        shutil.copy2(source, target)
        output_rows.append({**row, "output": output_name})
    return {
        "schemaVersion": 1,
        "arch": arch,
        "androidAbi": BUILD_TO_ANDROID_ABI.get(arch, "universal"),
        "availableAbis": manifest.get("availableAbis", []),
        "selected": output_rows,
    }


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
                    "dimension": split.dimension,
                    "selector": split.selector,
                }
            )
    return {
        "schemaVersion": 1,
        "bundle": str(bundle),
        "arch": arch,
        "androidAbi": BUILD_TO_ANDROID_ABI.get(arch, "universal"),
        "availableAbis": sorted({split.abi for split in splits if split.abi}),
        "selected": output_rows,
    }


def inspect_payload(path: Path) -> dict[str, object]:
    splits = inspect_bundle(path)
    return {
        "schemaVersion": 1,
        "bundle": str(path),
        "availableAbis": sorted({split.abi for split in splits if split.abi}),
        "availableBuildArches": derivable_build_arches(splits),
        "byteTotalsByDimension": _inspect_byte_totals(path, splits),
        "splits": _inspect_split_rows(path, splits),
    }


def _inspect_split_rows(path: Path, splits: list[Split]) -> list[dict[str, object]]:
    rows = []
    with zipfile.ZipFile(path) as zf:
        for split in splits:
            info = zf.getinfo(split.member)
            rows.append({
                "member": split.member,
                "abi": split.abi,
                "libAbis": list(split.lib_abis),
                "dimension": split.dimension,
                "selector": split.selector,
                "size": info.file_size,
                "containerCompressedSize": info.compress_size,
                "containerUncompressedSize": info.file_size,
            })
    return rows


def _inspect_byte_totals(path: Path, splits: list[Split]) -> dict[str, dict[str, int]]:
    totals: dict[str, dict[str, int]] = {}
    with zipfile.ZipFile(path) as zf:
        for split in splits:
            info = zf.getinfo(split.member)
            total = totals.setdefault(
                split.dimension,
                {
                    "splitCount": 0,
                    "apkBytes": 0,
                    "containerCompressedBytes": 0,
                    "containerUncompressedBytes": 0,
                },
            )
            total["splitCount"] += 1
            total["apkBytes"] += info.file_size
            total["containerCompressedBytes"] += info.compress_size
            total["containerUncompressedBytes"] += info.file_size
    return totals


def manifest_tree(text: str) -> list[tuple[str, dict[str, str]]]:
    """Read aapt2's XML tree. Reject unresolved topology attributes."""
    nodes: list[tuple[str, dict[str, str]]] = []
    for line in text.splitlines():
        element = re.match(r"\s*E: (\S+)(?: |$)", line)
        if element:
            nodes.append((element[1].rsplit(":", 1)[-1], {}))
            continue
        attr = re.match(r"\s*A: (.+?)(?:\(0x[0-9a-fA-F]+\))?=(.*)", line)
        if attr and nodes:
            name, value = attr.groups()
            android_prefix = "http://schemas.android.com/apk/res/android:"
            if name.startswith(android_prefix):
                name = name[len(android_prefix):]
            elif name.startswith("android:"):
                name = name[len("android:"):]
            elif ":" in name:
                # Keep foreign namespace identity. A vendor attribute such as
                # horizonos:name must not collide with android:name or be
                # interpreted as an Android topology field.
                name = name
            if value.startswith('"'):
                match = re.match(r'"([^"\\]*)"(?: \(Raw: .*\))?$', value)
                if not match:
                    raise BundleError(f"unsupported manifest string: {name}")
                value = match[1]
            elif not re.fullmatch(r"(?:0x[0-9a-fA-F]+|\d+|true|false)", value):
                # Resource references are common for ordinary application fields.
                # Keep them opaque; identity/topology consumers reject them.
                value = "?" + value
            if name in nodes[-1][1]:
                raise BundleError(f"duplicate manifest attribute: {name}")
            nodes[-1][1][name] = value
    if not nodes or nodes[0][0] != "manifest":
        raise BundleError("aapt2 did not return a manifest tree")
    return nodes


def resource_configs(text: str) -> dict[str, set[str]]:
    """Read every populated resource ID/configuration, including sparse tables."""
    if text.strip() == "Binary APK":
        return {}  # aapt2 can emit an empty table in an ABI-only APK.
    if not text.startswith("Binary APK\n") or not re.search(r"^Package name=", text, re.M):
        raise BundleError("unsupported aapt2 resource table")
    result: dict[str, set[str]] = {}
    current = None
    for line in text.splitlines():
        resource = re.match(r"\s+resource (0x[0-9a-fA-F]{8}) \S+", line)
        if resource:
            current = resource[1].lower()
            result.setdefault(current, set())
        else:
            config = re.match(r"\s+\(([^()]*)\) .+", line)
            if config:
                if current is None:
                    raise BundleError("resource configuration has no ID")
                result[current].add(config[1])
    if not result or any(not configs for configs in result.values()):
        raise BundleError("resource table has missing configuration evidence")
    return result


def _manifest_identity(attrs: dict[str, str]) -> tuple[str, int, str]:
    try:
        package = attrs["package"]
        code = int(attrs["versionCode"], 0) if attrs["versionCode"].startswith("0x") else int(attrs["versionCode"])
        version = attrs.get("versionName", "")
        major = attrs.get("versionCodeMajor", "0")
        if not package or package.startswith("?") or version.startswith("?") or int(major, 0) != 0:
            raise ValueError
        if not 0 < code <= 2100000000:
            raise ValueError
        return package, code, version
    except (KeyError, ValueError) as exc:
        raise BundleError("unsupported package/version identity") from exc


def _true(value: str) -> bool:
    if value in ("", "0", "0x00000000", "false"):
        return False
    if value in ("1", "0xffffffff", "0x00000001", "true"):
        return True
    raise BundleError(f"unsupported manifest boolean: {value}")


def _configuration_key(config: str, dimension: str, *, base: bool = False) -> str:
    if dimension == "density":
        if config == "":
            # Density delivery splits can carry unqualified defaults. Keep that
            # default as part of the split's coverage instead of discarding it.
            return ""
        # Density-targeted splits can legitimately carry orthogonal qualifiers,
        # e.g. ldrtl-xxhdpi or night-xxhdpi, and can contain fallback density
        # variants such as hdpi/xhdpi/anydpi. Remove exactly the density axis and
        # retain all other qualifiers as the coverage key.
        density = re.compile(r"(?:ldpi|mdpi|tvdpi|hdpi|xhdpi|xxhdpi|xxxhdpi|nodpi|anydpi|\d+dpi)")
        parts = config.split("-")
        matches = [index for index, part in enumerate(parts) if density.fullmatch(part)]
        if not matches and base:
            return config
        if len(matches) != 1:
            raise BundleError(f"mixed or unknown {dimension} resource configuration: {config}")
        if parts[matches[0]] in {"nodpi", "anydpi"}:
            # These modes control scaling and precedence. A scalable density
            # variant cannot replace them, even with the same resource ID.
            return config
        return "-".join(part for index, part in enumerate(parts) if index != matches[0])
    pattern = r"(?:[a-z]{2,3}(?:-r(?:[A-Z]{2}|\d{3}))?|b\+[A-Za-z0-9+]+)(?:-v\d+)?"
    if not re.fullmatch(pattern, config):
        raise BundleError(f"mixed or unknown {dimension} resource configuration: {config}")
    # Only the declared split dimension is removed. Preserve SDK qualifiers.
    match = re.search(r"(?:^|-)(v\d+)$", config)
    return match[1] if match else ""


def minimal_standalone(selected_dir: Path, arch: str, output_dir: Path,
                       aapt2: str) -> dict[str, object]:
    """Select whole APK members from a verified stock install set before merge.

    This supports base-owned configs only. Features, assets and unknown split
    dimensions require a separate topology proof and are rejected here.
    """
    if arch not in BUILD_TO_ANDROID_ABI:
        raise BundleError("minimal standalone requires a concrete ABI")
    paths = sorted(selected_dir.glob("*.apk"))
    if not paths or selected_dir.resolve().is_relative_to(output_dir.resolve()):
        raise BundleError("invalid standalone input/output directory")
    evidence = []
    split_ids: set[str] = set()
    required_types: set[str] = set()
    provided_types: dict[str, set[str]] = {}
    sanitized_resource_ids: set[str] = set()
    identity = None
    version_names: set[str] = set()
    base = None
    requested = BUILD_TO_ANDROID_ABI[arch]
    for path in paths:
        nodes = manifest_tree(run_aapt2(aapt2, path, "xmltree", "--file", "AndroidManifest.xml"))
        attrs = nodes[0][1]
        this_identity = _manifest_identity(attrs)
        identity = identity or this_identity
        if identity[:2] != this_identity[:2]:
            raise BundleError("split package/version identity mismatch")
        if this_identity[2]:
            version_names.add(this_identity[2])
        split_id = attrs.get("split", "")
        if split_id.startswith("?") or split_id in split_ids:
            raise BundleError("missing or duplicate split identity")
        split_ids.add(split_id)
        for tag, fields in nodes:
            if tag == "meta-data" and fields.get("name") == "com.android.vending.splits":
                reference = fields.get("resource", "")
                match = re.fullmatch(r"\??@(0x[0-9a-fA-F]{8})", reference)
                if match:
                    # APKEditor removes Play's split-list metadata when flattening.
                    # Its backing resource is therefore expected to disappear too.
                    sanitized_resource_ids.add(match[1].lower())
            for field in ("requiredSplitTypes", "splitTypes"):
                value = fields.get(field, "")
                if value.startswith("?"):
                    raise BundleError("unresolved split type requirement")
                types = {item.strip() for item in value.split(",") if item.strip()}
                if field == "requiredSplitTypes":
                    required_types.update(types)
                else:
                    provided_types.setdefault(split_id, set()).update(types)
            if _true(fields.get("isolatedSplits", "")):
                raise BundleError("isolated split loading is not supported")
        if (_true(attrs.get("isFeatureSplit", "")) or attrs.get("configForSplit", "")
                or any(tag in {"uses-split", "module"} for tag, _ in nodes)):
            raise BundleError("feature/dependency topology is not supported for minimal standalone")
        if split_id and not split_id.startswith("config."):
            raise BundleError(f"unknown split topology: {split_id}")
        config_manifest_fields = {
            "package", "versionCode", "versionCodeMajor", "versionName", "revisionCode",
            "compileSdkVersion", "compileSdkVersionCodename", "platformBuildVersionCode",
            "platformBuildVersionName", "split", "configForSplit", "isFeatureSplit",
            "targetConfig", "requiredSplitTypes", "splitTypes", "isSplitRequired",
        }
        if split_id and set(attrs) - config_manifest_fields:
            raise BundleError(f"config split has unsupported manifest attributes: {split_id}")
        if split_id:
            allowed_tags = {"manifest", "uses-sdk", "application", "meta-data"}
            if any(tag not in allowed_tags for tag, _ in nodes):
                raise BundleError(f"config split contains manifest behavior: {split_id}")
            for tag, fields in nodes:
                if tag != "meta-data":
                    continue
                # Play-generated config splits carry this distribution-only marker.
                # It does not define runtime component behavior and APKEditor removes
                # the split wrapper during standalone composition. Keep every other
                # metadata shape fail-closed.
                if (set(fields) - {"name", "value"}
                        or fields.get("name") != "com.android.vending.derived.apk.id"
                        or not re.fullmatch(r"(?:0x[0-9a-fA-F]+|\d+)", fields.get("value", ""))):
                    raise BundleError(f"config split contains unsupported meta-data: {split_id}")
        apps = [fields for tag, fields in nodes if tag == "application"]
        if len(apps) != 1:
            raise BundleError("split requires one application element")
        if split_id and set(apps[0]) - {"hasCode", "extractNativeLibs", "splitTypes", "requiredSplitTypes"}:
            raise BundleError(f"config split has unsupported application attributes: {split_id}")
        with zipfile.ZipFile(path) as apk:
            infos = [entry for entry in apk.infolist() if not entry.is_dir()]
            entries = [entry.filename for entry in infos]
            libs = tuple(abi for abi in ANDROID_ABIS if any(name.startswith(f"lib/{abi}/") for name in entries))
            dimension, selector = _classify_split(f"split_{split_id}.apk", _abi_from_name(f"{split_id}.apk"))
            if not split_id:
                dimension, selector = "core", "base"
            elif _true(apps[0].get("hasCode", "")) or any(DEX_RE.match(name) for name in entries):
                raise BundleError(f"config split contains code: {split_id}")
            configs = resource_configs(run_aapt2(aapt2, path, "resources")) if "resources.arsc" in entries else {}
            if split_id:
                allowed = {"AndroidManifest.xml", "resources.arsc"}
                unmodeled = [
                    entry for entry in infos
                    if (entry.filename not in allowed
                        and not entry.filename.startswith(("META-INF/", "res/", "lib/"))
                        and not (entry.filename == "stamp-cert-sha256" and entry.file_size == 32))
                ]
                if unmodeled:
                    raise BundleError(f"config split has unmodeled payload: {split_id}")
                if dimension not in {"abi", "density", "locale"}:
                    raise BundleError(f"unknown config dimension: {split_id}")
                if dimension == "abi":
                    if (selector != requested or libs != (requested,) or configs
                            or any(name.startswith("res/") for name in entries)
                            or any(name.startswith("lib/") and not name.startswith(f"lib/{requested}/") for name in entries)):
                        raise BundleError(f"ABI split is not a pure requested-ABI payload: {split_id}")
                elif any(name.startswith("lib/") for name in entries) or not configs:
                    raise BundleError(f"resource split is not a pure resource payload: {split_id}")
                else:
                    for configurations in configs.values():
                        for config in configurations:
                            _configuration_key(config, dimension)
        row = {"member": path.name, "splitId": split_id, "dimension": dimension, "libAbis": list(libs),
               "versionName": this_identity[2],
               "selector": selector, "size": path.stat().st_size, "sha256": _sha256(path)}
        evidence.append((path, row, configs))
        if not split_id:
            base = evidence[-1]
    if base is None:
        raise BundleError("minimal standalone requires base APK")
    base_abis = list(base[1]["libAbis"])
    if base_abis and base_abis != [requested]:
        raise BundleError("base APK contains foreign or multiple ABIs")
    base_supplies_requested_abi = base_abis == [requested]
    standalone_source = len(evidence) == 1 and base_supplies_requested_abi
    if not base_supplies_requested_abi and not any(
            row["dimension"] == "abi" for _, row, _ in evidence):
        raise BundleError("minimal standalone requires the requested ABI in base or an ABI split")
    if version_names - {str(base[1]["versionName"])}:
        raise BundleError("split versionName differs from base")
    assert identity is not None
    identity = (identity[0], identity[1], str(base[1]["versionName"]))
    defaults = {resource for resource, configs in base[2].items() if "" in configs}
    densities = [item for item in evidence if item[1]["dimension"] == "density"]
    base_coverage = {(resource, _configuration_key(config, "density", base=True))
                     for resource, configs in base[2].items() for config in configs}
    def coverage(item):
        return {(resource, _configuration_key(config, "density"))
                for resource, configs in item[2].items() for config in configs} - base_coverage
    needed = set().union(*(coverage(item) for item in densities))
    candidates = [item for item in densities if needed <= coverage(item)]
    # Select the highest complete density to retain image quality. Android scales
    # it on other screens. Keep the set when no single density has full coverage.
    def density_rank(item):
        selector = str(item[1]["selector"])
        dpi = {"ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240,
               "xhdpi": 320, "xxhdpi": 480, "xxxhdpi": 640}.get(selector)
        if dpi is None:
            match = re.fullmatch(r"(\d+)dpi", selector)
            if not match:
                raise BundleError(f"unsupported density selector: {selector}")
            dpi = int(match[1])
        return (-dpi, item[1]["size"], item[0].name)
    density = min(candidates, key=density_rank) if candidates and needed else None
    selected = []
    omitted = []
    for path, row, configs in evidence:
        reason = "required-base-or-abi"
        keep = True
        if row["dimension"] == "locale":
            keep = not set(configs) <= defaults
            reason = "locale-only-resource-ids" if keep else "base-default-resource-coverage"
        elif row["dimension"] == "density":
            keep = bool(needed) and (density is None or path == density[0])
            reason = "density-resource-coverage" if keep else "retained-resource-coverage"
        (selected if keep else omitted).append({**row, "reason": reason})
    supplied = set().union(*(provided_types.get(str(row["splitId"]), set()) for row in selected))
    # Manifest requirements can make an otherwise redundant config necessary.
    # Retain whole providers for those types instead of erasing the requirement.
    for row in sorted(omitted, key=lambda row: (row["size"], row["member"])):
        types = provided_types.get(str(row["splitId"]), set())
        if types & (required_types - supplied):
            selected.append({**row, "reason": "manifest-required-split-type"})
            supplied.update(types)
    selected_ids = {row["splitId"] for row in selected}
    omitted = [row for row in omitted if row["splitId"] not in selected_ids]
    if required_types - supplied:
        raise BundleError(f"selected set lacks required split types: {sorted(required_types - supplied)}")
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    for row in selected:
        shutil.copy2(selected_dir / str(row["member"]), output_dir / str(row["member"]))
    assert identity is not None
    required_configs: dict[str, set[str]] = {}
    for _, row, configs in evidence:
        if row["splitId"] in selected_ids:
            for resource, configurations in configs.items():
                if resource not in sanitized_resource_ids:
                    required_configs.setdefault(resource, set()).update(configurations)
    required_ids = set().union(*(set(item[2]) for item in evidence)) - sanitized_resource_ids
    return {"schemaVersion": 1, "strategy": "standalone-source" if standalone_source else "minimal-split-standalone", "arch": arch,
            "packageName": identity[0], "versionCode": identity[1], "versionName": identity[2],
            "versionCodePolicy": "preserve-upstream", "selected": selected, "omitted": omitted,
            "sanitizedResourceIds": sorted(sanitized_resource_ids),
            "requiredResourceIds": sorted(required_ids),
            "requiredResourceConfigs": {resource: sorted(configs) for resource, configs in sorted(required_configs.items())},
            "selectedBytes": sum(row["size"] for row in selected),
            "inputBytes": sum(path.stat().st_size for path in paths)}


DEX_RE = re.compile(r"(?:^|/)classes(?:\d+)?\.dex$")


def verify_standalone(apk: Path, plan: dict[str, object], aapt2: str) -> None:
    nodes = manifest_tree(run_aapt2(aapt2, apk, "xmltree", "--file", "AndroidManifest.xml"))
    attrs = nodes[0][1]
    if _manifest_identity(attrs) != (plan["packageName"], plan["versionCode"], plan["versionName"]):
        raise BundleError("standalone merge changed package/version identity")
    if any(attrs.get(field, "") for field in ("split", "configForSplit", "requiredSplitTypes", "splitTypes")):
        raise BundleError("merged APK retains split requirements")
    for tag, fields in nodes:
        if (tag == "uses-split" or _true(fields.get("isSplitRequired", ""))
                or fields.get("requiredSplitTypes", "") or _true(fields.get("isFeatureSplit", ""))):
            raise BundleError("merged APK still requires splits")
        if tag == "meta-data" and fields.get("name", "") == "com.android.vending.splits.required" and _true(fields.get("value", "")):
            raise BundleError("merged APK retains vending split requirement")
    with zipfile.ZipFile(apk) as archive:
        configs = resource_configs(run_aapt2(aapt2, apk, "resources")) if "resources.arsc" in archive.namelist() else {}
    if set(plan["requiredResourceIds"]) - set(configs):
        raise BundleError("merged APK lost required resource IDs")
    for resource, required in plan["requiredResourceConfigs"].items():
        if set(required) - configs.get(resource, set()):
            raise BundleError(f"merged APK lost required resource configurations: {resource}")


def _split_size_estimate(
    arch: str,
    *,
    policy: str,
    topology: str,
    preserve_bytes: int,
    preserve_count: int,
    total_count: int,
    selected_dir: Path | None = None,
    aapt2: str | None = None,
    total_bytes: int | None = None,
) -> dict[str, object]:
    if policy not in {"preserve", "minimal"}:
        raise BundleError(f"unsupported stock split policy: {policy}")

    estimated_bytes = preserve_bytes
    selected_count = preserve_count
    omitted_count = 0
    minimal_proven = False
    basis = "preserve-split-set"

    if policy == "minimal" and arch != "universal":
        if not aapt2:
            raise BundleError("minimal size estimate requires --aapt2")
        if selected_dir is None:
            raise BundleError("minimal size estimate requires a materialized split set")
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = minimal_standalone(
                selected_dir,
                arch,
                Path(tmp_dir) / "minimal",
                aapt2,
            )
        if int(plan["inputBytes"]) != preserve_bytes:
            raise BundleError("minimal selector input bytes differ from size estimate input")
        estimated_bytes = int(plan["selectedBytes"])
        selected_count = len(plan.get("selected", []))
        omitted_count = len(plan.get("omitted", []))
        minimal_proven = True
        basis = "proven-minimal-splits"

    evidence: dict[str, object] = {
        "topology": topology,
        "canBuildRequestedArch": True,
        "stockSplitPolicy": policy,
        "selectedSplitCount": selected_count,
        "totalSplitCount": total_count,
        "selectedMemberBytes": preserve_bytes,
        "minimalProven": minimal_proven,
        "minimalSavingsBytes": preserve_bytes - estimated_bytes,
        "omittedSplitCount": omitted_count,
    }
    if total_bytes is not None:
        evidence["totalMemberBytes"] = total_bytes

    return {
        "schemaVersion": 1,
        "arch": arch,
        "format": "BUNDLE",
        "topology": topology,
        "canBuildRequestedArch": True,
        "estimatedStandaloneBytes": estimated_bytes,
        "sizeEstimateBasis": basis,
        "sizeEstimatePolicy": policy,
        "sizeEstimateEvidence": evidence,
    }


def estimate_standalone_size(
    arch: str,
    *,
    bundle: Path | None = None,
    apk: Path | None = None,
    selected_dir: Path | None = None,
    partition_root: Path | None = None,
    aapt2: str | None = None,
    policy: str = "preserve",
) -> dict[str, object]:
    if policy not in {"preserve", "minimal"}:
        raise BundleError(f"unsupported stock split policy: {policy}")

    if apk is not None:
        if not apk.is_file():
            raise BundleError(f"APK does not exist: {apk}")
        try:
            with zipfile.ZipFile(apk) as zf:
                found = {
                    parts[1]
                    for name in zf.namelist()
                    if name.startswith("lib/")
                    for parts in [name.split("/", 2)]
                    if len(parts) >= 3 and parts[1] in ANDROID_ABIS
                }
        except zipfile.BadZipFile as exc:
            raise BundleError(f"not a ZIP-based APK: {apk}") from exc

        lib_abis = tuple(a for a in ANDROID_ABIS if a in found)
        if arch == "universal":
            if len(lib_abis) == 1:
                raise BundleError(f"single-ABI APK cannot derive universal: {apk}")
        else:
            requested = BUILD_TO_ANDROID_ABI.get(arch)
            if not requested:
                raise BundleError(f"unsupported build architecture: {arch}")
            if len(lib_abis) == 0:
                raise BundleError(f"ABI-independent APK cannot derive distinct {arch}")
            if len(lib_abis) > 1:
                raise BundleError(
                    f"flattened multi-ABI APK ({', '.join(lib_abis)}) cannot derive per-ABI {arch}"
                )
            if lib_abis[0] != requested:
                raise BundleError(
                    f"APK ABI ({lib_abis[0]}) does not match requested {arch} ({requested})"
                )

        size = apk.stat().st_size
        return {
            "schemaVersion": 1,
            "arch": arch,
            "format": "APK",
            "topology": "standalone",
            "canBuildRequestedArch": True,
            "estimatedStandaloneBytes": size,
            "sizeEstimateBasis": "standalone-apk",
            "sizeEstimatePolicy": policy,
            "sizeEstimateEvidence": {
                "topology": "standalone",
                "canBuildRequestedArch": True,
                "stockSplitPolicy": policy,
                "measuredBytes": size,
                "libAbis": list(lib_abis),
                "basis": "standalone-apk",
            },
        }

    if partition_root is not None:
        manifest_path = partition_root / "partition.json"
        try:
            manifest = json.loads(manifest_path.read_text())
        except (FileNotFoundError, json.JSONDecodeError) as exc:
            raise BundleError(f"invalid partition manifest: {manifest_path}") from exc

        available = manifest.get("availableBuildArches", [])
        if arch not in available:
            raise BundleError(
                f"partition can derive {', '.join(available) or 'no architectures'}, not {arch}"
            )

        rows = manifest.get("splits", [])
        if not isinstance(rows, list) or not rows:
            raise BundleError("partition has no splits")

        requested_abi = BUILD_TO_ANDROID_ABI.get(arch)
        if arch == "universal":
            selected = rows
        else:
            selected = [
                row for row in rows
                if row.get("dimension") != "abi" or row.get("abi") == requested_abi
            ]
        if not selected:
            raise BundleError(f"partition produced empty install set for {arch}")

        preserve_bytes = sum(int(row["size"]) for row in selected)
        total_bytes = sum(int(row["size"]) for row in rows)
        if policy == "minimal" and arch != "universal":
            with tempfile.TemporaryDirectory() as tmp_dir:
                tmp_selected = Path(tmp_dir) / "selected"
                tmp_selected.mkdir()
                for row in selected:
                    source_file = _verify_partition_file(partition_root, row)
                    shutil.copy2(source_file, tmp_selected / row["output"])
                return _split_size_estimate(
                    arch,
                    policy=policy,
                    topology="split-partition",
                    preserve_bytes=preserve_bytes,
                    preserve_count=len(selected),
                    total_count=len(rows),
                    selected_dir=tmp_selected,
                    aapt2=aapt2,
                    total_bytes=total_bytes,
                )
        return _split_size_estimate(
            arch,
            policy=policy,
            topology="split-partition",
            preserve_bytes=preserve_bytes,
            preserve_count=len(selected),
            total_count=len(rows),
            total_bytes=total_bytes,
        )

    if selected_dir is not None:
        if not selected_dir.is_dir():
            raise BundleError(f"selected splits directory does not exist: {selected_dir}")
        apk_files = sorted(
            p for p in selected_dir.iterdir()
            if p.is_file() and p.suffix.lower() == ".apk"
        )
        if not apk_files:
            raise BundleError(f"no split APKs found in: {selected_dir}")
        preserve_bytes = sum(p.stat().st_size for p in apk_files)
        return _split_size_estimate(
            arch,
            policy=policy,
            topology="split-bundle",
            preserve_bytes=preserve_bytes,
            preserve_count=len(apk_files),
            total_count=len(apk_files),
            selected_dir=selected_dir,
            aapt2=aapt2,
            total_bytes=preserve_bytes,
        )

    if bundle is not None:
        splits = inspect_bundle(bundle)
        available = derivable_build_arches(splits)
        if arch not in available:
            raise BundleError(
                f"bundle can derive {', '.join(available) or 'no build architectures'}, not {arch}"
            )
        selected = select_splits(splits, arch)
        with zipfile.ZipFile(bundle) as zf:
            member_sizes = {name: zf.getinfo(name).file_size for name in zf.namelist()}
        preserve_bytes = sum(member_sizes.get(split.member, 0) for split in selected)
        total_bytes = sum(member_sizes.get(split.member, 0) for split in splits)

        if policy == "minimal" and arch != "universal":
            with tempfile.TemporaryDirectory() as tmp_dir:
                tmp_selected = Path(tmp_dir) / "selected"
                extract_selected(bundle, arch, tmp_selected)
                return _split_size_estimate(
                    arch,
                    policy=policy,
                    topology="split-bundle",
                    preserve_bytes=preserve_bytes,
                    preserve_count=len(selected),
                    total_count=len(splits),
                    selected_dir=tmp_selected,
                    aapt2=aapt2,
                    total_bytes=total_bytes,
                )
        return _split_size_estimate(
            arch,
            policy=policy,
            topology="split-bundle",
            preserve_bytes=preserve_bytes,
            preserve_count=len(selected),
            total_count=len(splits),
            total_bytes=total_bytes,
        )

    raise BundleError("estimate-size requires --apk, --bundle, --selected-dir, or --partition-root")

def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("inspect")
    inspect.add_argument("--bundle", type=Path, required=True)
    partition = sub.add_parser("partition")
    partition.add_argument("--bundle", type=Path, required=True)
    partition.add_argument("--output-root", type=Path, required=True)
    materialize = sub.add_parser("materialize")
    materialize.add_argument("--partition-root", type=Path, required=True)
    materialize.add_argument("--arch", choices=["universal", *BUILD_TO_ANDROID_ABI], required=True)
    materialize.add_argument("--output-dir", type=Path, required=True)
    materialize.add_argument("--manifest", type=Path)
    select = sub.add_parser("select")
    select.add_argument("--bundle", type=Path, required=True)
    select.add_argument("--arch", choices=["universal", *BUILD_TO_ANDROID_ABI], required=True)
    select.add_argument("--output-dir", type=Path, required=True)
    select.add_argument("--manifest", type=Path)
    standalone = sub.add_parser("standalone")
    standalone.add_argument("--selected-dir", type=Path, required=True)
    standalone.add_argument("--arch", choices=list(BUILD_TO_ANDROID_ABI), required=True)
    standalone.add_argument("--output-dir", type=Path, required=True)
    standalone.add_argument("--aapt2", required=True)
    standalone.add_argument("--manifest", type=Path, required=True)
    verify = sub.add_parser("verify-standalone")
    verify.add_argument("--apk", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--aapt2", required=True)
    estimate_size = sub.add_parser("estimate-size")
    estimate_size.add_argument("--arch", choices=["universal", *BUILD_TO_ANDROID_ABI], required=True)
    estimate_size.add_argument("--bundle", type=Path)
    estimate_size.add_argument("--apk", type=Path)
    estimate_size.add_argument("--selected-dir", type=Path)
    estimate_size.add_argument("--partition-root", type=Path)
    estimate_size.add_argument("--aapt2")
    estimate_size.add_argument("--policy", choices=["preserve", "minimal"], default="preserve")
    estimate_size.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            payload = inspect_payload(args.bundle)
        elif args.command == "partition":
            payload = partition_bundle(args.bundle, args.output_root)
        elif args.command == "materialize":
            payload = materialize_partition(args.partition_root, args.arch, args.output_dir)
            if args.manifest:
                args.manifest.parent.mkdir(parents=True, exist_ok=True)
                args.manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        elif args.command == "standalone":
            payload = minimal_standalone(args.selected_dir, args.arch, args.output_dir, args.aapt2)
            args.manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        elif args.command == "verify-standalone":
            payload = json.loads(args.manifest.read_text())
            verify_standalone(args.apk, payload, args.aapt2)
            payload["mergedSha256"] = _sha256(args.apk)
            payload["mergedBytes"] = args.apk.stat().st_size
            args.manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        elif args.command == "estimate-size":
            payload = estimate_standalone_size(
                args.arch,
                bundle=args.bundle,
                apk=args.apk,
                selected_dir=args.selected_dir,
                partition_root=args.partition_root,
                aapt2=args.aapt2,
                policy=args.policy,
            )
            if args.manifest:
                args.manifest.parent.mkdir(parents=True, exist_ok=True)
                args.manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        else:
            payload = extract_selected(args.bundle, args.arch, args.output_dir)
            if args.manifest:
                args.manifest.parent.mkdir(parents=True, exist_ok=True)
                args.manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(json.dumps(payload, separators=(",", ":")))
        return 0
    except (BundleError, OSError, RuntimeError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        print(f"stock bundle error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
