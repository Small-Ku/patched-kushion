#!/usr/bin/env python3
"""Parse APKFab version inventories and resolve variant download links.

The adapter intentionally treats APKFab as an exact-version branch source: its
variant pages are device-profile specific, so a single APKFab payload must not
be promoted into a reusable broad/universal source node.
"""
from __future__ import annotations

import argparse
import html as html_lib
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable
from urllib.parse import urljoin, urlparse


ARCH_ALIASES = {
    "arm-v7a": "armeabi-v7a",
    "arm64-v8a": "arm64-v8a",
    "x86": "x86",
    "x86_64": "x86_64",
}
SIZE_UNITS = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}


def read_text(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8", errors="replace")


class VersionSpanParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.capture_depth: int | None = None
        self.parts: list[str] = []
        self.versions: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.depth += 1
        attrs_dict = {key: value or "" for key, value in attrs}
        classes = set(attrs_dict.get("class", "").split())
        if self.capture_depth is None and tag == "span" and "version" in classes:
            self.capture_depth = self.depth
            self.parts = []

    def handle_endtag(self, tag: str) -> None:
        if self.capture_depth == self.depth:
            value = " ".join("".join(self.parts).split()).strip().lstrip("v")
            if value:
                self.versions.append(value)
            self.capture_depth = None
            self.parts = []
        self.depth = max(0, self.depth - 1)

    def handle_data(self, data: str) -> None:
        if self.capture_depth is not None:
            self.parts.append(data)


def versions_from_html(raw: str) -> list[str]:
    parser = VersionSpanParser()
    parser.feed(raw)
    out: list[str] = []
    seen: set[str] = set()
    for value in parser.versions:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out


def text_from_html(raw: str) -> str:
    # APKFab renders variant metadata as ordinary HTML text. Keep separators so
    # labels such as Architecture/SHA1/Size do not run into adjacent fields.
    text = re.sub(r"(?is)<(?:script|style)\b.*?</(?:script|style)>", " ", raw)
    text = re.sub(r"(?s)<[^>]+>", "\n", text)
    text = html_lib.unescape(text).replace("\xa0", " ")
    return "\n".join(line.strip() for line in text.splitlines() if line.strip())


def size_bytes(value: str, unit: str) -> int:
    try:
        return int(float(value) * SIZE_UNITS[unit.upper()])
    except (KeyError, ValueError):
        return 0


def variant_rows(raw: str, version: str, base_url: str) -> list[dict[str, object]]:
    text = text_from_html(raw)
    escaped = re.escape(version.lstrip("v"))
    # Each APKFab variant repeats "version (versionCode)" followed by the
    # architecture, SHA1 and size. The app title before the version is purposely
    # ignored so this works for every configured APKFab application page.
    pattern = re.compile(
        rf"{escaped}\s*\((?P<code>\d+)\)"
        r".*?Architecture:\s*(?P<arch>[^\n]+)"
        r".*?Screen DPI:\s*(?P<dpi>[^\n]+)"
        r".*?SHA1:\s*(?P<sha1>[0-9a-fA-F]{40})"
        r".*?Size:\s*(?P<size>[0-9]+(?:\.[0-9]+)?)\s*(?P<unit>KB|MB|GB|B)\b",
        re.DOTALL | re.IGNORECASE,
    )
    rows: list[dict[str, object]] = []
    seen: set[str] = set()
    app_base = base_url.rstrip("/")
    for match in pattern.finditer(text):
        sha1 = match.group("sha1").lower()
        if sha1 in seen:
            continue
        seen.add(sha1)
        arches = [part.strip() for part in match.group("arch").split(",") if part.strip()]
        rows.append(
            {
                "version": version.lstrip("v"),
                "versionCode": int(match.group("code")),
                "architectures": arches,
                "dpi": match.group("dpi").strip(),
                "sha1": sha1,
                "sizeBytes": size_bytes(match.group("size"), match.group("unit")),
                "downloadPage": f"{app_base}/download?sha1={sha1}",
                "format": "XAPK",
            }
        )
    return rows


def select_variant(rows: Iterable[dict[str, object]], arch: str) -> dict[str, object] | None:
    wanted = ARCH_ALIASES.get(arch, arch)
    matching = [row for row in rows if wanted in row.get("architectures", [])]
    if not matching:
        return None
    # Prefer the newest variant code within an exact version, then the smallest
    # matching device profile to avoid needless transfer volume.
    return min(
        matching,
        key=lambda row: (
            -int(row.get("versionCode", 0) or 0),
            int(row.get("sizeBytes", 0) or 0) if int(row.get("sizeBytes", 0) or 0) > 0 else 2**63,
            str(row.get("sha1", "")),
        ),
    )


class LinkCollector(HTMLParser):
    URL_ATTRS = {"href", "src", "data-url", "data-href", "data-download-url", "data-apk-url", "content"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.values: list[tuple[str, str]] = []
        self.script_parts: list[str] = []
        self.in_script = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "script":
            self.in_script = True
        for key, value in attrs:
            if value and key.lower() in self.URL_ATTRS:
                self.values.append((key.lower(), value))

    def handle_endtag(self, tag: str) -> None:
        if tag == "script":
            self.in_script = False

    def handle_data(self, data: str) -> None:
        if self.in_script:
            self.script_parts.append(data)


def candidate_links(raw: str, page_url: str) -> list[str]:
    parser = LinkCollector()
    parser.feed(raw)
    values = list(parser.values)
    script_text = "\n".join(parser.script_parts).replace("\\/", "/")
    for value in re.findall(r"https?://[^\s\"'<>\\]+", script_text):
        values.append(("script", html_lib.unescape(value)))

    page = urlparse(page_url)
    scored: list[tuple[int, str]] = []
    seen: set[str] = set()
    for attr, value in values:
        value = html_lib.unescape(value).strip()
        if attr == "content" and "url=" in value.lower():
            value = re.split(r"url=", value, flags=re.IGNORECASE, maxsplit=1)[1].strip(" '\"")
        if not value or value.startswith(("javascript:", "mailto:", "#")):
            continue
        url = urljoin(page_url, value)
        if url in seen:
            continue
        seen.add(url)
        parsed = urlparse(url)
        path_lower = parsed.path.lower()
        if path_lower.endswith((".js", ".css", ".png", ".jpg", ".jpeg", ".svg", ".webp", ".ico")):
            continue
        if parsed.netloc == page.netloc and parsed.path == page.path and parsed.query == page.query:
            continue
        score = 0
        if re.search(r"\.(?:xapk|apk|apks|apkm)(?:$|[?#])", url, re.IGNORECASE):
            score += 120
        if "download" in path_lower or "download" in parsed.netloc.lower():
            score += 40
        if parsed.netloc and parsed.netloc != page.netloc:
            score += 30
        if attr.startswith("data-"):
            score += 15
        elif attr == "href":
            score += 10
        elif attr == "script":
            score += 5
        # The /download?sha1=... HTML page is an interstitial, not the payload.
        if parsed.netloc == page.netloc and parsed.path.rstrip("/").endswith("/download") and "sha1=" in parsed.query:
            score -= 100
        if score >= 40:
            scored.append((score, url))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [url for _, url in scored]


def cmd_versions(ns: argparse.Namespace) -> int:
    for version in versions_from_html(read_text(ns.html)):
        print(version)
    return 0


def cmd_inventory(ns: argparse.Namespace) -> int:
    rows = variant_rows(read_text(ns.html), ns.version, ns.base_url)
    json.dump(rows, sys.stdout, separators=(",", ":"))
    print()
    return 0


def cmd_select(ns: argparse.Namespace) -> int:
    rows = variant_rows(read_text(ns.html), ns.version, ns.base_url)
    selected = select_variant(rows, ns.arch)
    if selected is None:
        return 1
    json.dump(selected, sys.stdout, separators=(",", ":"))
    print()
    return 0


def cmd_resolve(ns: argparse.Namespace) -> int:
    links = candidate_links(read_text(ns.html), ns.page_url)
    if not links:
        return 1
    print(links[0])
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)

    versions = sub.add_parser("versions")
    versions.add_argument("--html", required=True)
    versions.set_defaults(func=cmd_versions)

    inventory = sub.add_parser("inventory")
    inventory.add_argument("--html", required=True)
    inventory.add_argument("--version", required=True)
    inventory.add_argument("--base-url", required=True)
    inventory.set_defaults(func=cmd_inventory)

    select = sub.add_parser("select")
    select.add_argument("--html", required=True)
    select.add_argument("--version", required=True)
    select.add_argument("--arch", required=True)
    select.add_argument("--base-url", required=True)
    select.set_defaults(func=cmd_select)

    resolve = sub.add_parser("resolve")
    resolve.add_argument("--html", required=True)
    resolve.add_argument("--page-url", required=True)
    resolve.set_defaults(func=cmd_resolve)
    return ap


def main() -> int:
    ns = build_parser().parse_args()
    return ns.func(ns)


if __name__ == "__main__":
    raise SystemExit(main())
