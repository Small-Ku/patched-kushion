#!/usr/bin/env python3
"""Build a stable security fingerprint for a stock Android APK.

The fingerprint intentionally ignores ZIP metadata and signing-block bytes. It
tracks the package/version/permission/component surface plus DEX and native
library content hashes, which are the parts most useful for spotting repackaged
or code-injected mirror artifacts.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any

DEX_RE = re.compile(r"(?:^|/)classes(?:\d+)?\.dex$")
COMPONENTS = {"activity", "activity-alias", "service", "receiver", "provider"}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def run_aapt2(aapt2: str | None, apk: Path, subcommand: str, *options: str) -> str:
    if not aapt2:
        return ""
    proc = subprocess.run(
        [aapt2, "dump", subcommand, str(apk), *options],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if proc.returncode:
        raise RuntimeError(f"aapt2 dump {subcommand} failed: {proc.stdout.strip()}")
    return proc.stdout


def parse_badging(text: str) -> dict[str, Any]:
    result: dict[str, Any] = {"permissions": []}
    package = re.search(
        r"^package:\s+name='([^']+)'(?:\s+versionCode='([^']*)')?(?:\s+versionName='([^']*)')?",
        text,
        re.MULTILINE,
    )
    if package:
        result["packageName"] = package.group(1)
        result["versionCode"] = package.group(2) or ""
        result["versionName"] = package.group(3) or ""
    for key, field in (("sdkVersion", "minSdk"), ("targetSdkVersion", "targetSdk")):
        match = re.search(rf"^{key}:'([^']+)'", text, re.MULTILINE)
        if match:
            result[field] = match.group(1)
    permissions = set()
    for match in re.finditer(r"^uses-permission(?:-sdk-23)?:\s+name='([^']+)'", text, re.MULTILINE):
        permissions.add(match.group(1))
    result["permissions"] = sorted(permissions)
    return result


def parse_xmltree_components(text: str) -> list[dict[str, Any]]:
    lines = text.splitlines()
    components: list[dict[str, Any]] = []
    i = 0
    while i < len(lines):
        match = re.match(r"^(\s*)E:\s+([A-Za-z0-9_.-]+)", lines[i])
        if not match or match.group(2) not in COMPONENTS:
            i += 1
            continue
        indent = len(match.group(1))
        kind = match.group(2)
        name = ""
        exported: bool | None = None
        j = i + 1
        while j < len(lines):
            child = re.match(r"^(\s*)E:\s+", lines[j])
            if child and len(child.group(1)) <= indent:
                break
            attr = lines[j]
            nm = re.search(r"android:name[^=]*=\"([^\"]+)\"", attr)
            if nm:
                name = nm.group(1)
            if "android:exported" in attr:
                if re.search(r'=\"true\"|\)0xffffffff\b', attr, re.IGNORECASE):
                    exported = True
                elif re.search(r'=\"false\"|\)0x0+\b', attr, re.IGNORECASE):
                    exported = False
            j += 1
        if name:
            row: dict[str, Any] = {"type": kind, "name": name}
            if exported is not None:
                row["exported"] = exported
            components.append(row)
        i = j
    return sorted(components, key=lambda row: (row["type"], row["name"], str(row.get("exported", ""))))


def scan_indicators(zf: zipfile.ZipFile, indicators: list[str]) -> list[dict[str, Any]]:
    needles = [(item, item.encode("utf-8")) for item in indicators if item]
    if not needles:
        return []
    matches: list[dict[str, Any]] = []
    for info in zf.infolist():
        name = info.filename
        lower = name.lower()
        if info.is_dir() or info.file_size > 64 * 1024 * 1024:
            continue
        if not (
            DEX_RE.search(name)
            or lower == "androidmanifest.xml"
            or lower.startswith("assets/")
            or lower.startswith("res/raw/")
        ):
            continue
        data = zf.read(info)
        for label, needle in needles:
            if needle in data:
                matches.append({"indicator": label, "entry": name})
    return sorted(matches, key=lambda row: (row["indicator"], row["entry"]))


def fingerprint(apk: Path, aapt2: str | None, indicators: list[str]) -> dict[str, Any]:
    with zipfile.ZipFile(apk) as zf:
        dex = []
        native = []
        manifest_sha = ""
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if name == "AndroidManifest.xml":
                manifest_sha = sha256_bytes(zf.read(info))
            elif DEX_RE.search(name):
                dex.append({"name": Path(name).name, "sha256": sha256_bytes(zf.read(info)), "size": info.file_size})
            elif name.startswith("lib/") and name.endswith(".so"):
                parts = name.split("/", 2)
                if len(parts) == 3:
                    native.append({"abi": parts[1], "name": parts[2], "sha256": sha256_bytes(zf.read(info)), "size": info.file_size})
        indicator_matches = scan_indicators(zf, indicators)

    badging = parse_badging(run_aapt2(aapt2, apk, "badging")) if aapt2 else {"permissions": []}
    components = parse_xmltree_components(run_aapt2(aapt2, apk, "xmltree", "--file", "AndroidManifest.xml")) if aapt2 else []
    dex = sorted(dex, key=lambda row: (row["name"], row["sha256"]))
    native = sorted(native, key=lambda row: (row["abi"], row["name"], row["sha256"]))

    comparison = {
        "packageName": badging.get("packageName", ""),
        "versionCode": badging.get("versionCode", ""),
        "versionName": badging.get("versionName", ""),
        "minSdk": badging.get("minSdk", ""),
        "targetSdk": badging.get("targetSdk", ""),
        "permissions": badging.get("permissions", []),
        "components": components,
        "dex": [{"sha256": row["sha256"], "size": row["size"]} for row in dex],
        "nativeLibraries": [
            {"abi": row["abi"], "name": row["name"], "sha256": row["sha256"], "size": row["size"]}
            for row in native
        ],
    }
    # If aapt2 is intentionally unavailable (unit tests/minimal hosts), retain a
    # manifest content signal so comparisons do not collapse to only code files.
    if not aapt2:
        comparison["manifestSha256"] = manifest_sha
    comparison_digest = sha256_bytes(
        json.dumps(comparison, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )
    return {
        "schemaVersion": 1,
        "artifactSha256": sha256_file(apk),
        "manifestSha256": manifest_sha,
        **badging,
        "components": components,
        "dex": dex,
        "nativeLibraries": native,
        "indicatorMatches": indicator_matches,
        "comparison": comparison,
        "comparisonSha256": comparison_digest,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--aapt2")
    parser.add_argument("--indicator", action="append", default=[])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fail-on-indicator", action="store_true")
    args = parser.parse_args()
    try:
        payload = fingerprint(args.apk, args.aapt2, args.indicator)
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        print(f"stock fingerprint error: {exc}", file=sys.stderr)
        return 1
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    if args.fail_on_indicator and payload["indicatorMatches"]:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
