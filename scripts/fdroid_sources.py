#!/usr/bin/env python3
"""Manage APK sources for the generated F-Droid repository."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

PACKAGE_RE = re.compile(
    r"package:\s+name='(?P<name>[^']+)'\s+versionCode='(?P<code>[^']+)'"
    r"(?:\s+versionName='(?P<version>[^']*)')?"
)
CERT_RE = re.compile(r"certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)")
NATIVE_CODE_RE = re.compile(r"native-code:\s*(.*)")
QUOTED_VALUE_RE = re.compile(r"'([^']+)'")
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SOURCE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class SourceError(RuntimeError):
    pass


@dataclass(frozen=True)
class ApkIdentity:
    package_name: str
    version_code: str
    version_name: str
    certificate_sha256: str
    sha256: str
    native_codes: tuple[str, ...]


@dataclass(frozen=True)
class Asset:
    source_name: str
    repository: str
    release_tag: str
    release_name: str
    published_at: str
    asset_id: int
    asset_name: str
    asset_url: str
    browser_download_url: str
    github_digest: str | None
    token_env: str | None


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def require_command(command: str) -> None:
    if shutil.which(command) is None:
        raise SourceError(f"Required command not found: {command}")


def normalize_fingerprint(value: str) -> str:
    result = re.sub(r"[^0-9A-Fa-f]", "", value).upper()
    if len(result) != 64:
        raise SourceError(f"Invalid SHA-256 certificate fingerprint: {value!r}")
    return result


def expand_repository(value: str) -> str:
    if value != "@self":
        return value
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not repository:
        raise SourceError("GITHUB_REPOSITORY is required for repository = '@self'")
    return repository


def source_environment(token_env: str | None) -> dict[str, str]:
    env = os.environ.copy()
    if token_env:
        token = env.get(token_env, "")
        if not token:
            raise SourceError(f"Source requires unset token environment variable: {token_env}")
        env["GH_TOKEN"] = token
    return env


def gh_json(endpoint: str, *, token_env: str | None) -> Any:
    completed = subprocess.run(
        ["gh", "api", endpoint],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=source_environment(token_env),
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise SourceError(f"GitHub API request failed for {endpoint}: {detail}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise SourceError(f"GitHub API returned invalid JSON for {endpoint}") from exc


def list_releases(repository: str, *, token_env: str | None, release_limit: int,
                  include_prereleases: bool) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    page = 1
    while len(selected) < release_limit:
        endpoint = f"repos/{repository}/releases?per_page=100&page={page}"
        response = gh_json(endpoint, token_env=token_env)
        if not isinstance(response, list):
            raise SourceError(f"Unexpected releases response for {repository}")
        for release in response:
            if release.get("draft"):
                continue
            if release.get("prerelease") and not include_prereleases:
                continue
            selected.append(release)
            if len(selected) == release_limit:
                break
        if len(response) < 100:
            break
        page += 1
    return selected


def matching_assets(source: dict[str, Any], *, newest_release_only: bool = False) -> list[Asset]:
    repository = expand_repository(str(source["repository"]))
    source_name = str(source.get("name") or repository)
    patterns = source.get("asset-patterns", ["*.apk"])
    if (
        not isinstance(patterns, list)
        or not patterns
        or not all(isinstance(value, str) for value in patterns)
    ):
        raise SourceError(f"{source_name}: asset-patterns must be a non-empty string array")
    release_limit = int(source.get("release-limit", 10))
    if release_limit < 1:
        raise SourceError(f"{source_name}: release-limit must be positive")
    include_prereleases = bool(source.get("include-prereleases", False))
    token_env_value = source.get("token-env")
    token_env = str(token_env_value) if token_env_value else None
    releases = list_releases(
        repository,
        token_env=token_env,
        release_limit=max(release_limit, 10) if newest_release_only else release_limit,
        include_prereleases=include_prereleases,
    )

    def assets_for_release(release: dict[str, Any]) -> list[Asset]:
        matched: list[Asset] = []
        for raw_asset in release.get("assets", []):
            name = str(raw_asset.get("name", ""))
            if not name.lower().endswith(".apk"):
                continue
            if not any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns):
                continue
            asset_id = raw_asset.get("id")
            if not isinstance(asset_id, int):
                raise SourceError(f"{repository} release asset {name!r} has no numeric ID")
            matched.append(
                Asset(
                    source_name=source_name,
                    repository=repository,
                    release_tag=str(release.get("tag_name", "")),
                    release_name=str(release.get("name") or ""),
                    published_at=str(release.get("published_at") or ""),
                    asset_id=asset_id,
                    asset_name=name,
                    asset_url=f"repos/{repository}/releases/assets/{asset_id}",
                    browser_download_url=str(raw_asset.get("browser_download_url") or ""),
                    github_digest=str(raw_asset["digest"]) if raw_asset.get("digest") else None,
                    token_env=token_env,
                )
            )
        return matched

    if newest_release_only:
        for release in releases:
            matched = assets_for_release(release)
            if matched:
                return matched
        return []

    result: list[Asset] = []
    for release in reversed(releases):
        result.extend(assets_for_release(release))
    return result


def download_asset(asset: Asset, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as output:
        completed = subprocess.run(
            ["gh", "api", "-H", "Accept: application/octet-stream", asset.asset_url],
            check=False,
            stdout=output,
            stderr=subprocess.PIPE,
            env=source_environment(asset.token_env),
        )
    if completed.returncode != 0:
        detail = completed.stderr.decode(errors="replace").strip()
        raise SourceError(
            f"Failed to download {asset.repository} release {asset.release_tag} "
            f"asset {asset.asset_name}: {detail}"
        )
    if not destination.is_file() or destination.stat().st_size == 0:
        raise SourceError(f"Downloaded empty APK: {asset.asset_name}")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def verify_github_digest(asset: Asset, actual_sha256: str) -> None:
    if not asset.github_digest:
        return
    algorithm, separator, expected = asset.github_digest.partition(":")
    if not separator or algorithm.lower() != "sha256":
        raise SourceError(
            f"Unsupported GitHub digest for {asset.asset_name}: {asset.github_digest}"
        )
    if expected.upper() != actual_sha256:
        raise SourceError(
            f"GitHub digest mismatch for {asset.asset_name}: "
            f"expected {expected.upper()}, got {actual_sha256}"
        )


def inspect_apk(path: Path) -> ApkIdentity:
    aapt = subprocess.run(
        ["aapt", "dump", "badging", str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if aapt.returncode != 0:
        raise SourceError(f"aapt rejected {path.name}: {aapt.stderr.strip()}")
    package_match = PACKAGE_RE.search(aapt.stdout)
    if not package_match:
        raise SourceError(f"Could not read package identity from {path.name}")

    signer = subprocess.run(
        ["apksigner", "verify", "--print-certs", str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if signer.returncode != 0:
        raise SourceError(f"apksigner rejected {path.name}: {signer.stderr.strip()}")
    certificate_match = CERT_RE.search(signer.stdout + "\n" + signer.stderr)
    if not certificate_match:
        raise SourceError(f"Could not read signer certificate from {path.name}")

    native_match = NATIVE_CODE_RE.search(aapt.stdout)
    native_codes = tuple(QUOTED_VALUE_RE.findall(native_match.group(1))) if native_match else ()

    return ApkIdentity(
        package_name=package_match.group("name"),
        version_code=package_match.group("code"),
        version_name=package_match.group("version") or "",
        certificate_sha256=normalize_fingerprint(certificate_match.group(1)),
        sha256=file_sha256(path),
        native_codes=native_codes,
    )


def validate_source_pins(source: dict[str, Any], identity: ApkIdentity) -> None:
    name = str(source.get("name") or source["repository"])
    allow_unpinned = bool(source.get("allow-unpinned", False))
    if allow_unpinned and source.get("repository") != "@self":
        raise SourceError(f"{name}: allow-unpinned is restricted to repository = '@self'")

    package_certificates = source.get("package-certificates", {})
    if not isinstance(package_certificates, dict):
        raise SourceError(f"{name}: package-certificates must be a table")
    for package_name, certificates in package_certificates.items():
        if not isinstance(package_name, str) or not isinstance(certificates, list):
            raise SourceError(
                f"{name}: package-certificates must map package names to arrays"
            )
        if not certificates or not all(isinstance(value, str) for value in certificates):
            raise SourceError(
                f"{name}: certificate pins for {package_name!r} must be a non-empty array"
            )

    if allow_unpinned:
        return
    if not package_certificates:
        raise SourceError(
            f"{name}: external sources must define package-certificates"
        )
    certificates = package_certificates.get(identity.package_name)
    if not certificates:
        raise SourceError(
            f"{name}: unexpected package {identity.package_name!r}; "
            f"allowed: {', '.join(sorted(package_certificates))}"
        )
    normalized_certificates = {
        normalize_fingerprint(str(value)) for value in certificates
    }
    if identity.certificate_sha256 not in normalized_certificates:
        raise SourceError(
            f"{name}: signer changed for {identity.package_name}: "
            f"{identity.certificate_sha256}"
        )


def load_config(path: Path) -> dict[str, Any]:
    try:
        config = tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SourceError(f"Source configuration not found: {path}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise SourceError(f"Invalid TOML in {path}: {exc}") from exc
    if config.get("version") != 1:
        raise SourceError(f"{path}: expected version = 1")
    sources = config.get("source")
    if not isinstance(sources, list) or not sources:
        raise SourceError(f"{path}: at least one [[source]] is required")
    seen_names: set[str] = set()
    for source in sources:
        if not isinstance(source, dict):
            raise SourceError(f"{path}: each source must be a table")
        name = str(source.get("name", "")).strip()
        repository = str(source.get("repository", "")).strip()
        if not name or not repository:
            raise SourceError(f"{path}: every source needs name and repository")
        if not SOURCE_NAME_RE.fullmatch(name):
            raise SourceError(
                f"{path}: source name must use only letters, digits, dot, "
                f"underscore, or dash: {name!r}"
            )
        if repository != "@self" and not REPOSITORY_RE.fullmatch(repository):
            raise SourceError(
                f"{path}: repository must be OWNER/REPOSITORY or @self: "
                f"{repository!r}"
            )
        token_env = source.get("token-env")
        if token_env is not None and (
            not isinstance(token_env, str) or not ENV_NAME_RE.fullmatch(token_env)
        ):
            raise SourceError(f"{path}: invalid token-env for source {name!r}")
        if name in seen_names:
            raise SourceError(f"{path}: duplicate source name {name!r}")
        seen_names.add(name)
    return config


def safe_filename_part(value: str) -> str:
    return SAFE_NAME_RE.sub("_", value).strip("._-") or "apk"


def sync_sources(config_path: Path, repo_dir: Path, provenance_path: Path) -> None:
    config = load_config(config_path)
    repo_dir.parent.mkdir(parents=True, exist_ok=True)
    provenance_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="fdroid-sync-", dir=repo_dir.parent) as temp_name:
        temp = Path(temp_name)
        downloads = temp / "downloads"
        staged_repo = temp / "repo"
        staged_repo.mkdir()
        records: list[dict[str, Any]] = []
        identities: dict[tuple[str, str, tuple[str, ...]], str] = {}
        output_by_sha: dict[str, Path] = {}

        for source in config["source"]:
            assets = matching_assets(source)
            source_name = str(source["name"])
            if not assets:
                raise SourceError(f"{source_name}: no matching APK release assets found")
            for index, asset in enumerate(assets):
                download_path = (
                    downloads
                    / safe_filename_part(source_name)
                    / f"{index:04d}-{safe_filename_part(asset.asset_name)}"
                )
                download_asset(asset, download_path)
                identity = inspect_apk(download_path)
                verify_github_digest(asset, identity.sha256)
                validate_source_pins(source, identity)

                identity_key = (identity.package_name, identity.version_code, identity.native_codes)
                previous_sha = identities.get(identity_key)
                if previous_sha and previous_sha != identity.sha256:
                    raise SourceError(
                        f"Conflicting APKs for {identity.package_name} versionCode "
                        f"{identity.version_code} nativeCodes={identity.native_codes}: "
                        f"{previous_sha} and {identity.sha256}"
                    )
                identities[identity_key] = identity.sha256

                if identity.sha256 not in output_by_sha:
                    abi_part = (
                        "_" + safe_filename_part("-".join(identity.native_codes))
                        if identity.native_codes else ""
                    )
                    filename = (
                        f"{safe_filename_part(identity.package_name)}_"
                        f"{safe_filename_part(identity.version_code)}{abi_part}_"
                        f"{identity.sha256[:12].lower()}.apk"
                    )
                    output = staged_repo / filename
                    shutil.copyfile(download_path, output)
                    output_by_sha[identity.sha256] = output

                records.append(
                    {
                        "source": source_name,
                        "repository": asset.repository,
                        "releaseTag": asset.release_tag,
                        "releaseName": asset.release_name,
                        "publishedAt": asset.published_at,
                        "assetName": asset.asset_name,
                        "assetUrl": asset.browser_download_url,
                        "packageName": identity.package_name,
                        "versionCode": identity.version_code,
                        "versionName": identity.version_name,
                        "sha256": identity.sha256,
                        "certificateSha256": identity.certificate_sha256,
                        "nativeCodes": list(identity.native_codes),
                        "githubDigest": asset.github_digest,
                        "repoFilename": output_by_sha[identity.sha256].name,
                    }
                )

        old_apks = list(repo_dir.glob("*.apk")) if repo_dir.exists() else []
        repo_dir.mkdir(parents=True, exist_ok=True)
        for apk in old_apks:
            apk.unlink()
        for apk in sorted(staged_repo.glob("*.apk")):
            shutil.move(str(apk), repo_dir / apk.name)

        manifest = {
            "schemaVersion": 1,
            "packages": sorted(
                records,
                key=lambda row: (
                    row["packageName"],
                    (0, int(row["versionCode"]))
                    if str(row["versionCode"]).isdigit()
                    else (1, str(row["versionCode"])),
                    row["repository"],
                    row["assetName"],
                ),
            ),
        }
        temporary_manifest = provenance_path.with_suffix(provenance_path.suffix + ".tmp")
        temporary_manifest.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary_manifest.replace(provenance_path)

    print(f"Prepared {len(output_by_sha)} unique APK(s) from {len(config['source'])} source(s):")
    for apk in sorted(repo_dir.glob("*.apk")):
        print(apk.name)


def toml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_array(values: Iterable[str]) -> str:
    return "[" + ", ".join(toml_quote(value) for value in values) + "]"


def add_source(args: argparse.Namespace) -> None:
    config_path = Path(args.config)
    config = load_config(config_path)
    if not REPOSITORY_RE.fullmatch(args.repository):
        raise SourceError("repository must use OWNER/REPOSITORY form")
    if args.token_env and not ENV_NAME_RE.fullmatch(args.token_env):
        raise SourceError(f"invalid token environment variable: {args.token_env!r}")

    name = args.name or args.repository.replace("/", "-")
    if not SOURCE_NAME_RE.fullmatch(name):
        raise SourceError("source name may use only letters, digits, dot, underscore, or dash")
    if any(str(source["name"]) == name for source in config["source"]):
        raise SourceError(f"Source name is already configured: {name}")

    candidate: dict[str, Any] = {
        "name": name,
        "repository": args.repository,
        "asset-patterns": args.pattern,
        "release-limit": args.release_limit,
        "include-prereleases": args.include_prereleases,
    }
    if args.token_env:
        candidate["token-env"] = args.token_env

    assets = matching_assets(candidate, newest_release_only=True)
    if not assets:
        raise SourceError("The newest eligible release has no matching APK assets")

    package_certificates: dict[str, set[str]] = {}
    identities: dict[tuple[str, str, tuple[str, ...]], str] = {}
    with tempfile.TemporaryDirectory(prefix="fdroid-add-source-") as temp_name:
        temp = Path(temp_name)
        for index, asset in enumerate(assets):
            path = temp / f"{index:04d}-{safe_filename_part(asset.asset_name)}"
            download_asset(asset, path)
            identity = inspect_apk(path)
            verify_github_digest(asset, identity.sha256)
            identity_key = (
                identity.package_name,
                identity.version_code,
                identity.native_codes,
            )
            previous_sha = identities.get(identity_key)
            if previous_sha and previous_sha != identity.sha256:
                raise SourceError(
                    "The selected assets contain conflicting APKs for "
                    f"{identity.package_name} versionCode {identity.version_code} "
                    f"nativeCodes={identity.native_codes}; narrow --pattern"
                )
            identities[identity_key] = identity.sha256
            package_certificates.setdefault(identity.package_name, set()).add(
                identity.certificate_sha256
            )

    block = [
        "",
        "[[source]]",
        f"name = {toml_quote(name)}",
        f"repository = {toml_quote(args.repository)}",
        f"asset-patterns = {toml_array(args.pattern)}",
        f"release-limit = {args.release_limit}",
        f"include-prereleases = {'true' if args.include_prereleases else 'false'}",
    ]
    if args.token_env:
        block.append(f"token-env = {toml_quote(args.token_env)}")
    block.append("")
    block.append("[source.package-certificates]")
    for package_name in sorted(package_certificates):
        block.append(
            f"{toml_quote(package_name)} = "
            f"{toml_array(sorted(package_certificates[package_name]))}"
        )
    block.append("")
    original = config_path.read_text(encoding="utf-8")
    temporary = config_path.with_suffix(config_path.suffix + ".tmp")
    temporary.write_text(original.rstrip() + "\n" + "\n".join(block), encoding="utf-8")
    temporary.replace(config_path)

    print(f"Added {args.repository} as source {name!r} to {config_path}")
    print("Pinned package identities:")
    for package_name in sorted(package_certificates):
        for certificate in sorted(package_certificates[package_name]):
            print(f"  {package_name} -> {certificate}")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)

    sync = subcommands.add_parser("sync", help="download and validate all configured sources")
    sync.add_argument("--config", default="fdroid/sources.toml")
    sync.add_argument("--repo-dir", required=True)
    sync.add_argument("--provenance", required=True)

    add = subcommands.add_parser("add", help="inspect and add an external GitHub release source")
    add.add_argument("repository", help="GitHub repository in OWNER/REPOSITORY form")
    add.add_argument("--config", default="fdroid/sources.toml")
    add.add_argument("--name")
    add.add_argument("--pattern", action="append", default=[])
    add.add_argument("--release-limit", type=int, default=5)
    add.add_argument("--include-prereleases", action="store_true")
    add.add_argument("--token-env")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        require_command("gh")
        require_command("aapt")
        require_command("apksigner")
        if getattr(args, "pattern", None) == []:
            args.pattern = ["*.apk"]
        if getattr(args, "release_limit", 1) < 1:
            raise SourceError("release-limit must be positive")
        if args.command == "sync":
            sync_sources(Path(args.config), Path(args.repo_dir), Path(args.provenance))
        else:
            add_source(args)
        return 0
    except (OSError, SourceError, subprocess.SubprocessError, ValueError) as exc:
        eprint(f"error: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
