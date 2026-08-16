#!/usr/bin/env python3
"""Validate stable app identities and render their public metadata."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PACKAGE_RE = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$")
PACKAGE_PREFIX = "de.kwoo.shion."


class CatalogError(RuntimeError):
    pass


@dataclass(frozen=True)
class App:
    key: str
    package_name: str
    display_name: str
    upstream_package: str
    patch_brand: str
    patches_source: str
    cli_source: str

    @property
    def patch_url(self) -> str:
        return f"https://github.com/{self.patches_source}"

    @property
    def cli_url(self) -> str:
        return f"https://github.com/{self.cli_source}"


def read_toml(path: Path) -> dict[str, Any]:
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise CatalogError(f"Could not read {path}: {exc}") from exc


def load_apps(config_path: Path) -> list[App]:
    config = read_toml(config_path)
    if config.get("config-version") != 1:
        raise CatalogError(f"{config_path} must have config-version = 1")
    build_defaults = config.get("build")
    if not isinstance(build_defaults, dict):
        raise CatalogError(f"{config_path} must contain a [build] table")
    raw_apps = config.get("apps")
    if not isinstance(raw_apps, dict) or not raw_apps:
        raise CatalogError(f"{config_path} must contain a non-empty [apps] table")
    signature_pins = config.get("upstream-signatures")
    if not isinstance(signature_pins, dict):
        raise CatalogError(f"{config_path} must contain an [upstream-signatures] table")

    default_patches = str(build_defaults.get("patches-source", "MorpheApp/morphe-patches"))
    default_cli = str(build_defaults.get("cli-source", "MorpheApp/morphe-desktop"))
    default_brand = str(build_defaults.get("patch-brand", "Morphe"))
    seen_packages: set[str] = set()
    apps: list[App] = []

    for key, raw in raw_apps.items():
        if not isinstance(key, str) or not isinstance(raw, dict):
            raise CatalogError("Every app must be a TOML table")
        build = raw.get("build")
        release = raw.get("release")
        if isinstance(build, dict) == isinstance(release, dict):
            raise CatalogError(f"{key}: define exactly one of .build or .release")
        if not isinstance(build, dict):
            continue

        required = ("upstream-package",)
        missing = [name for name in required if not isinstance(raw.get(name), str) or not raw[name]]
        if missing:
            raise CatalogError(f"{key}: missing or invalid fields: {', '.join(missing)}")
        upstream_package = str(raw["upstream-package"])
        pins = signature_pins.get(upstream_package)
        if not isinstance(pins, list) or not pins:
            raise CatalogError(
                f"{key}: third-party stock acquisition requires a pinned upstream signing certificate for {upstream_package}"
            )
        if any(not isinstance(pin, str) or not re.fullmatch(r"[0-9A-Fa-f]{64}", pin) for pin in pins):
            raise CatalogError(f"{key}: invalid SHA-256 certificate pin for {upstream_package}")

        build_mode = str(build.get("build-mode", "apk"))
        if build_mode not in {"apk", "module", "both"}:
            raise CatalogError(f"{key}: invalid build-mode {build_mode!r}")
        # Root-module-only targets have no installable non-root APK identity and
        # therefore must not be emitted into the F-Droid/public APK catalog.
        if build_mode == "module":
            continue

        package_name = raw.get("package-name")
        if not isinstance(package_name, str) or not package_name:
            raise CatalogError(f"{key}: missing or invalid fields: package-name")
        if not PACKAGE_RE.fullmatch(package_name):
            raise CatalogError(f"{key}: invalid lowercase Android package name: {package_name}")
        if not package_name.startswith(PACKAGE_PREFIX) or package_name == PACKAGE_PREFIX.rstrip("."):
            raise CatalogError(f"{key}: stable package must start with {PACKAGE_PREFIX}")
        if package_name in seen_packages:
            raise CatalogError(f"Several apps use package identity {package_name}")
        seen_packages.add(package_name)

        patches_source = str(build.get("patches-source", default_patches))
        if "patch-brand" in build:
            patch_brand = str(build["patch-brand"])
        elif "patch-brand" in build_defaults:
            patch_brand = default_brand
        else:
            repo_name = patches_source.rsplit("/", 1)[-1]
            if repo_name.endswith("-patches"):
                patch_brand = repo_name[:-8].capitalize()
            else:
                patch_brand = repo_name

        apps.append(
            App(
                key=key,
                package_name=package_name,
                display_name=str(raw.get("display-name") or key),
                upstream_package=upstream_package,
                patch_brand=patch_brand,
                patches_source=patches_source,
                cli_source=str(build.get("cli-source", default_cli)),
            )
        )

    if not apps:
        raise CatalogError(f"{config_path} contains no patched non-root apps")
    return sorted(apps, key=lambda app: app.display_name.casefold())

def markdown_catalog(apps: list[App]) -> str:
    lines = [
        "| App | Stable non-root package | Current patch bundle |",
        "|---|---|---|",
    ]
    for app in apps:
        lines.append(
            f"| {app.display_name} | `{app.package_name}` | "
            f"[{app.patch_brand}]({app.patch_url}) |"
        )
    return "\n".join(lines)

def yaml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def write_metadata(apps: list[App], metadata_dir: Path, repository: str) -> None:
    metadata_dir.mkdir(parents=True, exist_ok=True)
    source_url = f"https://github.com/{repository}"
    for app in apps:
        description = [
            "This is the stable non-root patched-kushion build of " + app.display_name + ".",
            "",
            f"Current patch bundle: {app.patch_brand} ({app.patches_source})",
            f"Patch frontend: {app.cli_source}",
            f"Upstream package: {app.upstream_package}",
            f"Stable package identity: {app.package_name}",
            "",
            "The patch implementation may change in a later release without changing this package identity. "
            "Build configuration and APK provenance are published in the source repository.",
        ]
        if app.patches_source == "MorpheApp/morphe-patches":
            description.extend(
                [
                    "",
                    "This is a modified patched-kushion build, not an official Morphe release and not affiliated with Morphe.",
                    "The Morphe NOTICE required by its patch license is included in the APK and source repository.",
                ]
            )
        body = [
            f"Name: {yaml_string(app.display_name)}",
            f"Summary: {yaml_string('Patched ' + app.display_name + ' build')}",
            "Description: |-",
            *(f"  {line}" if line else "" for line in description),
            f"SourceCode: {yaml_string(source_url)}",
            f"IssueTracker: {yaml_string(source_url + '/issues')}",
            "",
        ]
        (metadata_dir / f"{app.package_name}.yml").write_text(
            "\n".join(body), encoding="utf-8"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.toml")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    sub.add_parser("markdown")
    metadata = sub.add_parser("write-metadata")
    metadata.add_argument("--metadata-dir", required=True)
    metadata.add_argument("--repository", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        apps = load_apps(Path(args.config))
        if args.command == "validate":
            print(f"Validated {len(apps)} stable app identities")
        elif args.command == "markdown":
            print(markdown_catalog(apps))
        elif args.command == "write-metadata":
            write_metadata(apps, Path(args.metadata_dir), args.repository)
        else:  # pragma: no cover
            raise AssertionError(args.command)
        return 0
    except CatalogError as exc:
        print(f"app catalog error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
