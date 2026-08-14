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


AUTO_ARCHES = ["universal", "arm64-v8a", "arm-v7a", "x86_64", "x86"]


def normalize_arch(value: str) -> str:
    # Legacy `all` selected the builder's catch-all path. It now means the new
    # automatic output policy; concrete universal artifacts are always named
    # `universal` so policy and artifact identity cannot be confused again.
    return "universal" if value == "all" else value


def variant_axes(
    target: str, target_cfg: dict[str, Any]
) -> tuple[list[str], list[str], set[str], str]:
    arches_cfg = target_cfg.get("arches")
    optional_arches: set[str] = set()
    policy = "explicit"
    if arches_cfg is not None:
        if not isinstance(arches_cfg, list) or not arches_cfg or not all(isinstance(x, str) for x in arches_cfg):
            die(f"{target}: arches must be a non-empty array of architecture names")
        arches = list(dict.fromkeys(normalize_arch(x) for x in arches_cfg))
    else:
        arch_cfg = str(target_cfg.get("arch", "auto"))
        if arch_cfg in {"auto", "all"}:
            arches = list(AUTO_ARCHES)
            # Auto outputs are opportunistic capabilities. Every run probes all
            # standard ABIs plus a universal artifact and publishes whichever the
            # configured stock sources can actually produce. Skips are retried on
            # later runs so newly-added upstream splits appear automatically.
            optional_arches = set(arches)
            policy = "auto"
        elif arch_cfg == "both":
            arches = ["arm64-v8a", "arm-v7a"]
        else:
            arches = [normalize_arch(arch_cfg)]

    valid_arches = set(AUTO_ARCHES)
    invalid_arches = [arch for arch in arches if arch not in valid_arches]
    if invalid_arches:
        die(f"{target}: unsupported architectures: {', '.join(invalid_arches)}")

    mode_cfg = str(target_cfg.get("build-mode", "apk"))
    modes = ["apk", "module"] if mode_cfg == "both" else [mode_cfg]
    return arches, modes, optional_arches, policy


def download_release_asset(asset: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    endpoint = f"repos/{asset['repository']}/releases/assets/{asset['assetId']}"
    with path.open("wb") as out:
        proc = subprocess.run(["gh", "api", "-H", "Accept: application/octet-stream", endpoint], stdout=out, stderr=subprocess.PIPE)
    if proc.returncode:
        die(f"could not download {asset['assetName']}: {proc.stderr.decode(errors='replace').strip()}")


def highest_version(values: list[str]) -> str:
    return max(values, key=version_sort_key)


def version_sort_key(value: str) -> tuple:
    raw = value.lstrip("v")
    parts = re.split(r"[.-]", raw)
    cooked = []
    for part in parts:
        cooked.append((0, int(part)) if part.isdigit() else (1, part))
    return tuple(cooked)


def sort_versions(values: list[str]) -> list[str]:
    return sorted(dict.fromkeys(v.lstrip("v") for v in values if v), key=version_sort_key, reverse=True)


def resolve_patch_versions(cli: Path, patches: Path, package_name: str, version_mode: str) -> list[str] | None:
    """Return patch-compatible concrete versions, newest first.

    ``None`` means the patch bundle accepts any stock version and source inventory
    must provide the concrete candidates.  For version-pinned patch sets we keep
    every version that exposes the maximum compatible patch count instead of
    collapsing immediately to one version; the source stage can then fall back to
    an older compatible stock release without changing the patch/builder inputs.
    """
    if version_mode not in {"auto", "latest", "beta"}:
        return [version_mode.lstrip("v")]
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
    return sort_versions([version for version, count in rows if count == maximum])


def archive_inventory(url: str, package_name: str) -> dict[str, set[str]]:
    """Return stock artifact capabilities advertised by the archive index.

    A source ``all``/``universal`` artifact can be a universal APK or a split container. Both can
    produce architecture-specific variants: universal APKs are stripped before
    patching, while split containers are filtered before APKEditor merges them.
    """
    proc = subprocess.run(["curl", "-fsSL", url], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode:
        die(f"could not read stock artifact inventory from {url}: {proc.stderr.strip()}")
    pattern = re.compile(
        re.escape(package_name)
        + r"-(.+?)-(all|universal|arm64-v8a|arm-v7a|x86_64|x86)\.(?:apk|apkm|apks|xapk)"
    )
    result: dict[str, set[str]] = {}
    for version, arch in pattern.findall(proc.stdout):
        result.setdefault(version, set()).add(normalize_arch(arch))
    return result


def derivable_arches(inventory_arches: set[str], configured_arches: list[str]) -> list[str]:
    if "universal" not in inventory_arches:
        return [arch for arch in configured_arches if arch in inventory_arches]
    # An archive "universal" entry may be a multi-ABI APK or a split container.
    # It is therefore a useful hint that every configured ABI may be derivable.
    return [arch for arch in configured_arches if arch in AUTO_ARCHES]


def resolve_target_versions_and_hints(
    target: str,
    target_cfg: dict[str, Any],
    configured_arches: list[str],
    cli_asset: dict[str, Any],
    patches_asset: dict[str, Any],
    temp_dir: Path,
) -> tuple[list[str], list[str], list[str]]:
    """Resolve the build version without making one mirror an ABI gate.

    The archive index remains useful for ``latest``/``Any`` version discovery and
    as a diagnostic hint. Architecture output requirements come from config and
    are resolved against all configured download sources in the build job.
    """
    package_name = str(target_cfg.get("pkg-name", ""))
    if not package_name:
        die(f"{target}: pkg-name is required for variant discovery")
    cli_path = temp_dir / cli_asset["assetName"]
    patches_path = temp_dir / patches_asset["assetName"]
    if not cli_path.exists():
        download_release_asset(cli_asset, cli_path)
    if not patches_path.exists():
        download_release_asset(patches_asset, patches_path)

    version_mode = str(target_cfg.get("version", "auto"))
    compatible = resolve_patch_versions(cli_path, patches_path, package_name, version_mode)
    archive_url = str(target_cfg.get("archive-dlurl", ""))
    inventory: dict[str, set[str]] = {}
    if archive_url:
        inventory = archive_inventory(archive_url, package_name)

    if compatible is None:
        if not inventory:
            die(
                f"{target}: version {version_mode!r} needs a discoverable stock version; "
                "configure archive-dlurl or an explicit version"
            )
        candidates = sort_versions(list(inventory))
    else:
        candidates = list(compatible)
        # Keep older archive versions that are also explicitly advertised by the
        # patch bundle.  For an exact version list this is a no-op, while a patch
        # bundle exposing several fully-compatible releases gains stock fallback.
        candidates = sort_versions(candidates)
    if not candidates:
        die(f"{target}: no concrete version candidates could be resolved")
    candidates = candidates[:8]
    selected = candidates[0]
    archive_arches = derivable_arches(inventory.get(selected, set()), configured_arches)
    return candidates, list(configured_arches), archive_arches


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
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if not args.repository:
        die("--repository or GITHUB_REPOSITORY is required")

    config = tomllib.loads(args.config.read_text())
    if config.get("config-version") != 1:
        die("config.toml must have config-version = 1")
    state = load_state(args.state)

    global_cfg = config.get("build", {})
    if not isinstance(global_cfg, dict):
        die("config.toml must contain a [build] table")
    apps_cfg = config.get("apps", {})
    if not isinstance(apps_cfg, dict):
        die("config.toml must contain an [apps] table")
    default_patches_src = str(global_cfg.get("patches-source", "MorpheApp/morphe-patches"))
    default_patches_ver = str(global_cfg.get("patches-version", "latest"))
    default_cli_src = str(global_cfg.get("cli-source", "MorpheApp/morphe-desktop"))
    default_cli_ver = str(global_cfg.get("cli-version", "latest"))

    builder_paths = [
        Path("build.sh"), Path("utils.sh"), Path("scripts/stock_bundle.py"),
        args.config, Path("NOTICE")
    ]
    builder_paths.extend(Path("module").rglob("*"))
    builder_paths.extend(Path("bin").rglob("*"))
    builder_digest = file_digest(builder_paths)

    release_cache: dict[tuple[str, str, str], dict[str, Any]] = {}
    desired: list[dict[str, Any]] = []
    availability: list[dict[str, Any]] = []
    plan_temp = tempfile.TemporaryDirectory(prefix="patched-kushion-plan-")
    plan_temp_root = Path(plan_temp.name)
    for target, app_cfg in apps_cfg.items():
        if not isinstance(app_cfg, dict):
            die(f"{target}: app configuration must be a table")
        raw_build_cfg = app_cfg.get("build")
        if not isinstance(raw_build_cfg, dict):
            continue
        if raw_build_cfg.get("enabled", True) is False:
            continue
        target_cfg = dict(raw_build_cfg)
        target_cfg.setdefault("app-name", str(app_cfg.get("display-name") or target))
        target_cfg.setdefault("pkg-name", str(app_cfg.get("upstream-package") or ""))
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

        configured_arches, modes, optional_arches, arch_policy = variant_axes(target, target_cfg)
        identity = app_cfg
        version_candidates, arches, archive_arches = resolve_target_versions_and_hints(
            target, target_cfg, configured_arches, cli, patches, plan_temp_root
        )
        selected_version = version_candidates[0]
        availability.append({
            "target": target,
            "version": selected_version,
            "versionCandidates": version_candidates,
            "configuredArches": configured_arches,
            "availableArches": arches,
            "optionalArches": [arch for arch in arches if arch in optional_arches],
            "archPolicy": arch_policy,
            "missingArches": [],
            "archiveHintArches": archive_arches,
            "archiveMissingArches": [arch for arch in configured_arches if arch not in archive_arches],
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
            "availableArches": arches,
        }
        base_input = sha_json(relevant)
        for arch in arches:
            for mode in modes:
                key = safe_key(target, arch, mode)
                candidate_input_ids = {
                    version: sha_json({"base": base_input, "version": version, "arch": arch, "mode": mode})
                    for version in version_candidates
                }
                input_id = candidate_input_ids[selected_version]
                desired.append({
                    "key": key,
                    "target": target,
                    "arch": arch,
                    "mode": mode,
                    "version": selected_version,
                    "versionCandidates": version_candidates,
                    "candidateInputIds": candidate_input_ids,
                    "inputId": input_id,
                    "optional": arch in optional_arches,
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
            row = {k: item[k] for k in (
                "key", "target", "arch", "mode", "version", "versionCandidates",
                "candidateInputIds", "inputId", "optional"
            )}
            if isinstance(previous, dict):
                previous_version = str(previous.get("version", ""))
                previous_input = str(previous.get("inputId", ""))
                expected_previous_input = item["candidateInputIds"].get(previous_version)
                if (
                    expected_previous_input
                    and previous_input == expected_previous_input
                    and isinstance(asset_id, int)
                    and confirmed_assets.get(asset_id) == previous.get("assetName")
                ):
                    row["reuse"] = {
                        "version": previous_version,
                        "inputId": previous_input,
                        "assetId": asset_id,
                        "assetName": previous.get("assetName"),
                        "sha256": previous.get("sha256", ""),
                        "releaseTag": previous.get("releaseTag", ""),
                    }
            matrix.append(row)

    # Source discovery/download/partition is shared by the whole app/version.
    # Each target branch downloads the broadest split container once, partitions
    # it once, then fans out architecture merge workflows. APK/module patch jobs
    # fan out again from each prepared architecture stock artifact.
    targets_by_key: dict[str, dict[str, Any]] = {}
    for item in matrix:
        target_key = re.sub(r"[^a-z0-9]+", "-", str(item["target"]).lower()).strip("-")
        target_branch = targets_by_key.setdefault(target_key, {
            "key": target_key,
            "target": item["target"],
            "version": item["version"],
            "versions": item["versionCandidates"],
            "arches": {},
        })
        arch_key = f"{target_key}--{item['arch']}"
        arch_branch = target_branch["arches"].setdefault(arch_key, {
            "key": arch_key,
            "arch": item["arch"],
            "optional": item["optional"],
            "variants": [],
        })
        arch_branch["variants"].append({
            "key": item["key"],
            "mode": item["mode"],
            "inputId": item["inputId"],
            "candidateInputIds": item["candidateInputIds"],
            "reuse": item.get("reuse"),
            "optional": item["optional"],
        })

    targets: list[dict[str, Any]] = []
    arch_branches: list[dict[str, Any]] = []
    for key in sorted(targets_by_key):
        branch = targets_by_key[key]
        arches = [branch["arches"][arch_key] for arch_key in sorted(branch["arches"])]
        arch_branches.extend(arches)
        targets.append({
            "key": branch["key"],
            "target": branch["target"],
            "version": branch["version"],
            "versions": branch["versions"],
            "arches": arches,
        })

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
        "branches": arch_branches,
        "targets": targets,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"include": targets}, separators=(",", ":")))


if __name__ == "__main__":
    main()
