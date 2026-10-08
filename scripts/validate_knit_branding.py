#!/usr/bin/env python3
"""Fail closed when a patched APK is missing its planned Knit launcher identity."""
from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

TARGETS = {
    "KouTube": ("de.kwoo.shion.youtube", "KnitTube"),
    "KouMusik": ("de.kwoo.shion.music", "KnitMusic"),
    "KouPhotos": ("de.kwoo.shion.photos", "KnitPhotos"),
    "KouInstagram": ("de.kwoo.shion.instagram", "Knitstagram"),
    "KouMessenger": ("de.kwoo.shion.messenger", "KnitMessenger"),
}
ANDROID = "android"


@dataclass
class Node:
    tag: str
    attrs: dict[str, str] = field(default_factory=dict)
    children: list["Node"] = field(default_factory=list)


def run(*command: str) -> str:
    process = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", check=False)
    if process.returncode:
        raise SystemExit(process.stderr.strip() or f"command failed: {command[0]}")
    return process.stdout


def xmltree(text: str) -> Node:
    root = Node("root")
    stack: list[tuple[int, Node]] = [(-1, root)]
    for line in text.splitlines():
        indent = len(line) - len(line.lstrip())
        content = line.strip()
        if content.startswith("E: "):
            tag = content[3:].split(" ", 1)[0].split("(", 1)[0]
            while stack[-1][0] >= indent:
                stack.pop()
            node = Node(tag)
            stack[-1][1].children.append(node)
            stack.append((indent, node))
        elif content.startswith("A: ") and len(stack) > 1:
            match = re.match(r"A: (?:android:)?([\w-]+)(?:\([^)]*\))?=(.*)", content)
            if not match:
                continue
            key, value = match.groups()
            quoted = re.match(r'"(.*?)"', value)
            resource = re.match(r"@(0x[0-9a-fA-F]+)", value)
            if quoted:
                stack[-1][1].attrs[key] = quoted.group(1)
            elif resource:
                stack[-1][1].attrs[key] = "@" + resource.group(1).lower()
            else:
                stack[-1][1].attrs[key] = value.strip()
    return root


def find_app(root: Node) -> Node:
    manifest = next((node for node in root.children if node.tag == "manifest"), None)
    if manifest is None:
        raise SystemExit("APK manifest has no <manifest>")
    app = next((node for node in manifest.children if node.tag == "application"), None)
    if app is None:
        raise SystemExit("APK manifest has no <application>")
    return app


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--target", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--aapt", required=True)
    parser.add_argument("--aapt2", required=True)
    args = parser.parse_args()

    if args.target not in TARGETS:
        raise SystemExit(f"Knit branding is not configured for target {args.target}")
    expected_package, expected_name = TARGETS[args.target]
    if args.package != expected_package:
        raise SystemExit(f"{args.target} expects package {expected_package}, got {args.package}")
    if not args.apk.is_file():
        raise SystemExit(f"APK does not exist: {args.apk}")

    resources = run(args.aapt2, "dump", "resources", str(args.apk))
    manifest_text = run(args.aapt, "dump", "xmltree", str(args.apk), "AndroidManifest.xml")
    package_match = re.search(r'\bpackage="([^"]+)"', manifest_text)
    if package_match is None or package_match.group(1) != expected_package:
        actual = package_match.group(1) if package_match else "missing"
        raise SystemExit(f"APK package mismatch: expected {expected_package}, got {actual}")

    icon_id_match = re.search(r"resource (0x[0-9a-fA-F]+) mipmap/knit_launcher\b", resources)
    if icon_id_match is None:
        raise SystemExit("Knit mipmap/knit_launcher resource is missing from the resource table")
    icon_id = "@" + icon_id_match.group(1).lower()
    required_resources = (
        "drawable/knit_launcher_background",
        "drawable/knit_launcher_foreground",
        "drawable/knit_launcher_legacy_background",
        "drawable/knit_launcher_monochrome",
        "res/mipmap/knit_launcher.xml",
        "res/mipmap-anydpi-v26/knit_launcher.xml",
        "res/mipmap-anydpi-v33/knit_launcher.xml",
    )
    missing = [name for name in required_resources if name not in resources]
    if missing:
        raise SystemExit("Knit launcher resources are missing: " + ", ".join(missing))

    root = xmltree(manifest_text)
    app = find_app(root)
    if app.attrs.get("label") != expected_name:
        raise SystemExit(f"application label mismatch: expected {expected_name}")
    if app.attrs.get("icon") != icon_id or app.attrs.get("roundIcon") != icon_id:
        raise SystemExit("application icon and roundIcon must reference mipmap/knit_launcher")

    launchers: list[Node] = []
    for component in app.children:
        if component.tag not in {"activity", "activity-alias"}:
            continue
        actions = {child.attrs.get("name") for intent in component.children if intent.tag == "intent-filter"
                   for child in intent.children if child.tag == "action"}
        categories = {child.attrs.get("name") for intent in component.children if intent.tag == "intent-filter"
                      for child in intent.children if child.tag == "category"}
        if "android.intent.action.MAIN" in actions and "android.intent.category.LAUNCHER" in categories:
            launchers.append(component)
    if not launchers:
        raise SystemExit("APK manifest has no MAIN/LAUNCHER activity or alias")
    for component in launchers:
        if component.attrs.get("label") != expected_name:
            raise SystemExit("a MAIN/LAUNCHER component has no Knit launcher label")
        if component.attrs.get("icon") != icon_id:
            raise SystemExit("a MAIN/LAUNCHER component does not reference mipmap/knit_launcher")
    print(f"Knit launcher verified: {expected_name}; {len(launchers)} launcher components; {icon_id}")


if __name__ == "__main__":
    main()
