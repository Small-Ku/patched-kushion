#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
import xml.etree.ElementTree as ET

ANDROID = "http://schemas.android.com/apk/res/android"
LABEL = f"{{{ANDROID}}}label"
NAME = f"{{{ANDROID}}}name"
ET.register_namespace("android", ANDROID)


def launcher_components(app: ET.Element) -> list[ET.Element]:
    result: list[ET.Element] = []
    for tag in ("activity", "activity-alias"):
        for node in app.findall(tag):
            for intent in node.findall("intent-filter"):
                actions = {x.get(NAME, "") for x in intent.findall("action")}
                categories = {x.get(NAME, "") for x in intent.findall("category")}
                if "android.intent.action.MAIN" in actions and "android.intent.category.LAUNCHER" in categories:
                    result.append(node)
                    break
    return result


def apply_name(decoded: Path, name: str) -> int:
    manifest = decoded / "AndroidManifest.xml"
    if not manifest.is_file():
        raise SystemExit(f"decoded APK has no AndroidManifest.xml: {decoded}")
    tree = ET.parse(manifest)
    root = tree.getroot()
    app = root.find("application")
    if app is None:
        raise SystemExit("decoded manifest has no <application>")
    app.set(LABEL, name)
    launchers = launcher_components(app)
    for node in launchers:
        node.set(LABEL, name)
    tree.write(manifest, encoding="utf-8", xml_declaration=True)
    return len(launchers)


def safe_overlay_path(raw: str) -> PurePosixPath:
    path = PurePosixPath(raw.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "res":
        raise SystemExit(f"launcher icon overlay may only contain res/... paths: {raw}")
    return path


def copy_overlay_file(source: Path, rel: PurePosixPath, decoded: Path) -> None:
    dest = decoded.joinpath(*rel.parts)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, dest)


def apply_overlay(decoded: Path, overlay: Path) -> int:
    count = 0
    if overlay.is_dir():
        for source in sorted(overlay.rglob("*")):
            if not source.is_file():
                continue
            rel = safe_overlay_path(source.relative_to(overlay).as_posix())
            copy_overlay_file(source, rel, decoded)
            count += 1
    elif overlay.is_file() and overlay.suffix.lower() == ".zip":
        with zipfile.ZipFile(overlay) as archive, tempfile.TemporaryDirectory(prefix="launcher-overlay-") as tmp:
            root = Path(tmp)
            for info in archive.infolist():
                if info.is_dir():
                    continue
                rel = safe_overlay_path(info.filename)
                source = root.joinpath(*rel.parts)
                source.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as src, source.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                copy_overlay_file(source, rel, decoded)
                count += 1
    else:
        raise SystemExit(f"launcher icon overlay must be a directory or .zip: {overlay}")
    if count == 0:
        raise SystemExit(f"launcher icon overlay is empty: {overlay}")
    return count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decoded", required=True, type=Path)
    parser.add_argument("--name", default="")
    parser.add_argument("--icon-overlay", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    launchers = 0
    overlay_files = 0
    if args.name:
        launchers = apply_name(args.decoded, args.name)
    if args.icon_overlay:
        overlay_files = apply_overlay(args.decoded, args.icon_overlay)
    if args.report:
        import json
        args.report.write_text(json.dumps({"schemaVersion": 1, "launcherComponents": launchers, "overlayFiles": overlay_files}, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
