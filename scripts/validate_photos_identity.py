#!/usr/bin/env python3
"""Fail-only Photos manifest contract, independently parsed from aapt2 xmltree output."""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET

TARGET = "de.kwoo.shion.photos"
MARS = TARGET + ".api.mars"


def parse_xmltree(text: str) -> ET.Element:
    stack: list[tuple[int, ET.Element]] = []
    root = None
    for line in text.splitlines():
        indent = len(line) - len(line.lstrip())
        node = re.match(r"\s*E: ([\w-]+)(?:\s|$)", line)
        if node:
            while stack and stack[-1][0] >= indent:
                stack.pop()
            element = ET.Element(node[1])
            if stack:
                stack[-1][1].append(element)
            elif root is None:
                root = element
            else:
                raise ValueError("Multiple manifest roots")
            stack.append((indent, element))
        attribute = re.match(r'\s*A: ((?:(?:http://schemas.android.com/apk/res/android|android):)?[\w-]+)(?:\([^)]*\))?="([^"]*)"', line)
        if attribute and stack:
            key = attribute[1].replace('http://schemas.android.com/apk/res/android:', 'android:')
            stack[-1][1].set(key, attribute[2])
    if root is None or root.tag != "manifest":
        raise ValueError("Missing aapt2 manifest tree")
    return root


def validate(manifest: ET.Element) -> None:
    if manifest.get("package") != TARGET:
        raise ValueError("KouPhotos package contract failed")
    providers = [p for p in manifest.findall("./application/provider") if p.get("android:name", "").endswith(".MarsStoreProvider")]
    if len(providers) != 1 or providers[0].get("android:authorities") != MARS:
        raise ValueError("KouPhotos MarsStoreProvider authority contract failed")
    hosts = [data.get("android:host", "") for data in manifest.findall("./application/*/intent-filter/data")]
    if MARS not in hosts:
        raise ValueError("KouPhotos linked Mars intent host is missing")
    for node in manifest.iter():
        for key in ("android:authorities", "android:host"):
            for value in node.get(key, "").split(';'):
                if value.endswith(".api.mars") and value != MARS:
                    raise ValueError(f"Colliding/legacy Mars identity remains: {value}")


def main() -> None:
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        validate(parse_xmltree(sys.stdin.read()))
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print("KouPhotos distribution identity contract passed")


if __name__ == "__main__":
    main()
