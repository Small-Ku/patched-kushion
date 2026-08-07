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
    target: str
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


def load_apps(identity_path: Path, config_path: Path) -> list[App]:
    identities = read_toml(identity_path)
    config = read_toml(config_path)
    if identities.get("version") != 1:
        raise CatalogError("package-identities.toml must have version = 1")
    raw_apps = identities.get("apps")
    if not isinstance(raw_apps, dict) or not raw_apps:
        raise CatalogError("package-identities.toml must contain a non-empty [apps] table")

    default_patches = str(config.get("patches-source", "ReVanced/revanced-patches"))
    default_cli = str(config.get("cli-source", "ReVanced/revanced-cli"))
    default_brand = str(config.get("rv-brand", "ReVanced"))
    seen_targets: set[str] = set()
    seen_packages: set[str] = set()
    apps: list[App] = []

    for key, raw in raw_apps.items():
        if not isinstance(key, str) or not isinstance(raw, dict):
            raise CatalogError("Every app identity must be a TOML table")
        required = ("target", "package-name", "display-name", "upstream-package")
        missing = [name for name in required if not isinstance(raw.get(name), str) or not raw[name]]
        if missing:
            raise CatalogError(f"{key}: missing or invalid fields: {', '.join(missing)}")

        target = str(raw["target"])
        package_name = str(raw["package-name"])
        if not PACKAGE_RE.fullmatch(package_name):
            raise CatalogError(f"{key}: invalid lowercase Android package name: {package_name}")
        if not package_name.startswith(PACKAGE_PREFIX) or package_name == PACKAGE_PREFIX.rstrip("."):
            raise CatalogError(f"{key}: stable package must start with {PACKAGE_PREFIX}")
        if target in seen_targets:
            raise CatalogError(f"Several app identities select target {target}")
        if package_name in seen_packages:
            raise CatalogError(f"Several apps use package identity {package_name}")
        seen_targets.add(target)
        seen_packages.add(package_name)

        target_config = config.get(target)
        if not isinstance(target_config, dict):
            raise CatalogError(f"{key}: configured target does not exist: {target}")
        logical_name = str(target_config.get("app-name", target))
        if logical_name != key and not target.startswith(key):
            raise CatalogError(
                f"{key}: target {target} has app-name {logical_name!r}; expected {key!r}"
            )
        if target_config.get("enabled", True) is False:
            raise CatalogError(f"{key}: target {target} is disabled")
        build_mode = str(target_config.get("build-mode", "apk"))
        if build_mode not in {"apk", "both"}:
            raise CatalogError(
                f"{key}: target {target} must build a non-root APK, not {build_mode!r}"
            )

        patches_source = str(target_config.get("patches-source", default_patches))
        if "rv-brand" in target_config:
            patch_brand = str(target_config["rv-brand"])
        elif "rv-brand" in config:
            patch_brand = str(config["rv-brand"])
        else:
            repo_name = patches_source.rsplit("/", 1)[-1]
            if repo_name.endswith("-patches"):
                patch_brand = repo_name[:-8].capitalize()
                if patch_brand.lower() == "revanced":
                    patch_brand = "ReVanced"
            else:
                patch_brand = repo_name

        apps.append(
            App(
                key=key,
                target=target,
                package_name=package_name,
                display_name=str(raw["display-name"]),
                upstream_package=str(raw["upstream-package"]),
                patch_brand=patch_brand,
                patches_source=patches_source,
                cli_source=str(target_config.get("cli-source", default_cli)),
            )
        )

    return sorted(apps, key=lambda app: app.display_name.casefold())


def markdown_catalog(apps: list[App]) -> str:
    lines = [
        "| App | Stable non-root package | Current patch bundle | Build target |",
        "|---|---|---|---|",
    ]
    for app in apps:
        lines.append(
            f"| {app.display_name} | `{app.package_name}` | "
            f"[{app.patch_brand}]({app.patch_url}) | `{app.target}` |"
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
    parser.add_argument("--identities", default="package-identities.toml")
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
        apps = load_apps(Path(args.identities), Path(args.config))
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
