#!/usr/bin/env python3
"""Plan patched-kushion build variants from configured inputs and saved state."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib
from typing import Any

SCHEMA_VERSION = 1


def die(message: str) -> "NoReturn":
    raise SystemExit(message)


def gh_json(endpoint: str) -> Any:
    proc = subprocess.run(["gh", "api", endpoint], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode:
        die(f"gh api {endpoint} failed: {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        die(f"gh api {endpoint} returned invalid JSON: {exc}")


def gh_json_optional(endpoint: str) -> Any | None:
    proc = subprocess.run(["gh", "api", endpoint], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def release_for(repository: str, version: str) -> dict[str, Any]:
    if version == "latest":
        value = gh_json(f"repos/{repository}/releases/latest")
    elif version == "dev":
        releases = gh_json(f"repos/{repository}/releases?per_page=100&page=1")
        if not isinstance(releases, list) or not releases:
            die(f"{repository}: no releases found")
        value = releases[0]
    else:
        value = gh_json(f"repos/{repository}/releases/tags/{version}")
    if not isinstance(value, dict):
        die(f"{repository}: unexpected release response")
    return value


def pick_asset(release: dict[str, Any], kind: str, repository: str) -> dict[str, Any]:
    assets = [a for a in release.get("assets", []) if isinstance(a, dict)]
    if kind == "patches":
        matches = [a for a in assets if str(a.get("name", "")).endswith(".mpp")]
    else:
        matches = [a for a in assets if str(a.get("name", "")).endswith(".jar")]
        if len(matches) > 1:
            preferred = [
                a for a in matches
                if str(a.get("name", "")).endswith("-all.jar")
                and "-dev" not in str(a.get("name", ""))
            ]
            if len(preferred) == 1:
                matches = preferred
    if len(matches) > 1:
        stable = [a for a in matches if "-dev" not in str(a.get("name", ""))]
        if len(stable) == 1:
            matches = stable
    if not matches:
        die(f"{repository}: release {release.get('tag_name')} has no {kind} asset")
    asset = matches[0]
    asset_id = asset.get("id")
    if not isinstance(asset_id, int) or isinstance(asset_id, bool):
        die(f"{repository}: selected asset has no numeric id")
    return {
        "repository": repository,
        "releaseTag": str(release.get("tag_name", "")),
        "assetId": asset_id,
        "assetName": str(asset.get("name", "")),
        "digest": str(asset.get("digest") or ""),
    }


def sha_json(value: Any) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(raw).hexdigest()


def file_digest(paths: list[Path]) -> str:
    h = hashlib.sha256()
    for path in sorted(paths, key=lambda p: str(p)):
        if not path.is_file():
            continue
        h.update(str(path).encode() + b"\0")
        h.update(path.read_bytes())
        h.update(b"\0")
    return h.hexdigest()


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schemaVersion": SCHEMA_VERSION, "variants": {}}
    try:
        state = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        die(f"invalid build state {path}: {exc}")
    if not isinstance(state, dict) or state.get("schemaVersion") != SCHEMA_VERSION or not isinstance(state.get("variants"), dict):
        die(f"unsupported build state in {path}")
    return state


def release_tag_for_generation(repository: str, generation: str) -> str:
    releases = gh_json(f"repos/{repository}/releases?per_page=100&page=1")
    maximum = 0
    marker = f"<!-- patched-kushion-generation:{generation} -->"
    if isinstance(releases, list):
        for rel in releases:
            if not isinstance(rel, dict):
                continue
            tag = str(rel.get("tag_name", ""))
            if marker in str(rel.get("body", "")):
                return tag
            if tag.isdigit():
                maximum = max(maximum, int(tag))
    return str(maximum + 1)


def safe_key(target: str, arch: str, mode: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", target.lower()).strip("-")
    return f"{base}--{arch}--{mode}"


def variant_axes(target: str, target_cfg: dict[str, Any]) -> tuple[list[str], list[str]]:
    arches_cfg = target_cfg.get("arches")
    if arches_cfg is not None:
        if not isinstance(arches_cfg, list) or not arches_cfg or not all(isinstance(x, str) for x in arches_cfg):
            die(f"{target}: arches must be a non-empty array of architecture names")
        arches = list(dict.fromkeys(arches_cfg))
    else:
        arch_cfg = str(target_cfg.get("arch", "all"))
        arches = ["arm64-v8a", "arm-v7a"] if arch_cfg == "both" else [arch_cfg]

    valid_arches = {"all", "arm64-v8a", "arm-v7a", "x86_64", "x86"}
    invalid_arches = [arch for arch in arches if arch not in valid_arches]
    if invalid_arches:
        die(f"{target}: unsupported architectures: {', '.join(invalid_arches)}")

    mode_cfg = str(target_cfg.get("build-mode", "apk"))
    modes = ["apk", "module"] if mode_cfg == "both" else [mode_cfg]
    return arches, modes


def download_release_asset(asset: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    endpoint = f"repos/{asset['repository']}/releases/assets/{asset['assetId']}"
    with path.open("wb") as out:
        proc = subprocess.run(["gh", "api", "-H", "Accept: application/octet-stream", endpoint], stdout=out, stderr=subprocess.PIPE)
    if proc.returncode:
        die(f"could not download {asset['assetName']}: {proc.stderr.decode(errors='replace').strip()}")


def highest_version(values: list[str]) -> str:
    def key(value: str) -> tuple:
        raw = value.lstrip("v")
        parts = re.split(r"[.-]", raw)
        cooked = []
        for part in parts:
            cooked.append((0, int(part)) if part.isdigit() else (1, part))
        return tuple(cooked)
    return max(values, key=key)


def resolve_patch_version(cli: Path, patches: Path, package_name: str, version_mode: str) -> str | None:
    if version_mode not in {"auto", "latest", "beta"}:
        return version_mode.lstrip("v")
    if version_mode in {"latest", "beta"}:
        return None
    proc = subprocess.run([
        "java", "-jar", str(cli), "list-versions", "--patches", str(patches),
        "--filter-package-names", package_name,
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode:
        die(f"could not list patch versions for {package_name}: {proc.stderr.strip() or proc.stdout.strip()}")
    tail = proc.stdout.split("Most common compatible versions:", 1)
    if len(tail) != 2:
        die(f"could not parse patch versions for {package_name}")
    body = tail[1].strip()
    if body == "Any":
        return None
    rows: list[tuple[str, int]] = []
    for line in body.splitlines():
        m = re.match(r"\s*(\S+)\s+\((\d+)\s+patch", line)
        if m:
            rows.append((m.group(1), int(m.group(2))))
    if not rows:
        die(f"no compatible patch version found for {package_name}")
    maximum = max(count for _, count in rows)
    return highest_version([version for version, count in rows if count == maximum]).lstrip("v")


def archive_inventory(url: str, package_name: str) -> dict[str, set[str]]:
    proc = subprocess.run(["curl", "-fsSL", url], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode:
        die(f"could not read stock APK inventory from {url}: {proc.stderr.strip()}")
    pattern = re.compile(re.escape(package_name) + r"-(.+?)-(all|arm64-v8a|arm-v7a|x86_64|x86)\.apk")
    result: dict[str, set[str]] = {}
    for version, arch in pattern.findall(proc.stdout):
        result.setdefault(version, set()).add(arch)
    return result


def available_arches_for_target(target: str, target_cfg: dict[str, Any], allowed_arches: list[str], cli_asset: dict[str, Any], patches_asset: dict[str, Any], temp_dir: Path) -> tuple[str, list[str]]:
    package_name = str(target_cfg.get("pkg-name", ""))
    archive_url = str(target_cfg.get("archive-dlurl", ""))
    if not package_name or not archive_url:
        die(f"{target}: pkg-name and archive-dlurl are required for variant discovery")
    cli_path = temp_dir / cli_asset["assetName"]
    patches_path = temp_dir / patches_asset["assetName"]
    if not cli_path.exists():
        download_release_asset(cli_asset, cli_path)
    if not patches_path.exists():
        download_release_asset(patches_asset, patches_path)
    inventory = archive_inventory(archive_url, package_name)
    if not inventory:
        die(f"{target}: stock APK inventory is empty")
    version_mode = str(target_cfg.get("version", "auto"))
    selected = resolve_patch_version(cli_path, patches_path, package_name, version_mode)
    if selected is None:
        selected = highest_version(list(inventory))
    available = inventory.get(selected, set())
    return selected, [arch for arch in allowed_arches if arch in available]


def release_checkpoint(repository: str, tag: str, generation: str) -> dict[str, Any] | None:
    release = gh_json_optional(f"repos/{repository}/releases/tags/{tag}")
    if not isinstance(release, dict):
        return None
    state_asset = next(
        (a for a in release.get("assets", []) if isinstance(a, dict) and a.get("name") == "patched-kushion-build-state.json" and isinstance(a.get("id"), int)),
        None,
    )
    if state_asset is None:
        return None
    proc = subprocess.run(
        ["gh", "api", "-H", "Accept: application/octet-stream", f"repos/{repository}/releases/assets/{state_asset['id']}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if proc.returncode:
        return None
    try:
        recovered = json.loads(proc.stdout.decode())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if (
        isinstance(recovered, dict)
        and recovered.get("schemaVersion") == SCHEMA_VERSION
        and recovered.get("generation") == generation
        and str(recovered.get("releaseTag", "")) == tag
        and isinstance(recovered.get("variants"), dict)
    ):
        return recovered
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("config.toml"))
    parser.add_argument("--identities", type=Path, default=Path("package-identities.toml"))
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if not args.repository:
        die("--repository or GITHUB_REPOSITORY is required")

    config = tomllib.loads(args.config.read_text())
    identities = tomllib.loads(args.identities.read_text())
    state = load_state(args.state)

    global_cfg = {k: v for k, v in config.items() if not isinstance(v, dict)}
    default_patches_src = str(global_cfg.get("patches-source", "MorpheApp/morphe-patches"))
    default_patches_ver = str(global_cfg.get("patches-version", "latest"))
    default_cli_src = str(global_cfg.get("cli-source", "MorpheApp/morphe-desktop"))
    default_cli_ver = str(global_cfg.get("cli-version", "latest"))

    builder_paths = [Path("build.sh"), Path("utils.sh"), args.identities, Path("NOTICE"), Path("sig.txt")]
    builder_paths.extend(Path("module").rglob("*"))
    builder_paths.extend(Path("bin").rglob("*"))
    builder_digest = file_digest(builder_paths)

    release_cache: dict[tuple[str, str, str], dict[str, Any]] = {}
    desired: list[dict[str, Any]] = []
    availability: list[dict[str, Any]] = []
    plan_temp = tempfile.TemporaryDirectory(prefix="patched-kushion-plan-")
    plan_temp_root = Path(plan_temp.name)
    identity_by_target: dict[str, dict[str, Any]] = {}
    for logical, row in identities.get("apps", {}).items():
        if isinstance(row, dict) and isinstance(row.get("target"), str):
            identity_by_target[row["target"]] = {"logical": logical, **row}

    for target, target_cfg in config.items():
        if not isinstance(target_cfg, dict) or target_cfg.get("enabled", True) is False:
            continue
        patches_src = str(target_cfg.get("patches-source", default_patches_src))
        patches_ver = str(target_cfg.get("patches-version", default_patches_ver))
        cli_src = str(target_cfg.get("cli-source", default_cli_src))
        cli_ver = str(target_cfg.get("cli-version", default_cli_ver))
        pkey = ("patches", patches_src, patches_ver)
        ckey = ("cli", cli_src, cli_ver)
        if pkey not in release_cache:
            release_cache[pkey] = pick_asset(release_for(patches_src, patches_ver), "patches", patches_src)
        if ckey not in release_cache:
            release_cache[ckey] = pick_asset(release_for(cli_src, cli_ver), "cli", cli_src)
        patches = release_cache[pkey]
        cli = release_cache[ckey]

        configured_arches, modes = variant_axes(target, target_cfg)
        identity = identity_by_target.get(target, {})
        selected_version, arches = available_arches_for_target(
            target, target_cfg, configured_arches, cli, patches, plan_temp_root
        )
        availability.append({
            "target": target,
            "version": selected_version,
            "configuredArches": configured_arches,
            "availableArches": arches,
            "missingArches": [arch for arch in configured_arches if arch not in arches],
        })

        relevant = {
            "target": target,
            "config": target_cfg,
            "global": {
                k: global_cfg.get(k)
                for k in ("compression-level", "enable-module-update", "patches-source", "patches-version", "cli-source", "cli-version", "patch-brand")
                if k in global_cfg
            },
            "identity": identity,
            "patches": patches,
            "cli": cli,
            "builderDigest": builder_digest,
            "version": selected_version,
            "availableArches": arches,
        }
        base_input = sha_json(relevant)
        for arch in arches:
            for mode in modes:
                key = safe_key(target, arch, mode)
                input_id = sha_json({"base": base_input, "arch": arch, "mode": mode})
                desired.append({
                    "key": key,
                    "target": target,
                    "arch": arch,
                    "mode": mode,
                    "version": selected_version,
                    "inputId": input_id,
                    "patches": patches,
                    "cli": cli,
                    "packageName": identity.get("package-name", "") if mode == "apk" else "",
                })

    desired.sort(key=lambda x: x["key"])
    generation = sha_json([{"key": x["key"], "inputId": x["inputId"]} for x in desired])
    prior_generation = str(state.get("generation", ""))
    prior_tag = str(state.get("releaseTag", ""))
    release_tag = release_tag_for_generation(args.repository, generation)
    if prior_generation != generation or prior_tag != release_tag:
        recovered = release_checkpoint(args.repository, release_tag, generation)
        if recovered is not None:
            state = recovered
            prior_generation = generation
            prior_tag = release_tag

    confirmed_assets: dict[int, str] = {}
    checkpoint_tag = prior_tag if prior_generation == generation and prior_tag else release_tag
    if checkpoint_tag:
        release = gh_json_optional(f"repos/{args.repository}/releases/tags/{checkpoint_tag}")
        if isinstance(release, dict):
            for asset in release.get("assets", []):
                if isinstance(asset, dict) and isinstance(asset.get("id"), int):
                    confirmed_assets[int(asset["id"])] = str(asset.get("name", ""))

    matrix: list[dict[str, Any]] = []
    variants = state.get("variants", {})
    for item in desired:
        previous = variants.get(item["key"], {}) if isinstance(variants, dict) else {}
        asset_id = previous.get("assetId") if isinstance(previous, dict) else None
        satisfied = (
            isinstance(previous, dict)
            and previous.get("inputId") == item["inputId"]
            and isinstance(asset_id, int)
            and confirmed_assets.get(asset_id) == previous.get("assetName")
        )
        item["satisfied"] = bool(satisfied)
        if args.force or not satisfied:
            matrix.append({k: item[k] for k in ("key", "target", "arch", "mode", "version", "inputId")})

    plan = {
        "schemaVersion": SCHEMA_VERSION,
        "repository": args.repository,
        "generation": generation,
        "releaseTag": release_tag,
        "previousGeneration": prior_generation,
        "previousReleaseTag": prior_tag,
        "builderDigest": builder_digest,
        "availability": availability,
        "desired": desired,
        "matrix": matrix,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"include": matrix}, separators=(",", ":")))


if __name__ == "__main__":
    main()
