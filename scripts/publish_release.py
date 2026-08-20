#!/usr/bin/env python3
"""Publish successful build results to a reusable GitHub Release.

A plan variant identifies one target/architecture/mode. A build result may add a
version-specific ``variantKey``/``key`` pair so multiple compatible upstream app
versions can coexist in one release. ``variants`` keeps only the preferred
(newest) result for consumers that need one answer, while ``artifactsByInputId``
keeps every compatible result for cross-run reuse within the same generation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile
from typing import Any

SCHEMA_VERSION = 1


def run(args: list[str], *, stdout=None) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=False, stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE, text=stdout is None)


def check(args: list[str]) -> str:
    proc = run(args)
    if proc.returncode:
        detail = proc.stderr.strip() if isinstance(proc.stderr, str) else str(proc.stderr)
        raise SystemExit(f"{' '.join(args)} failed: {detail}")
    return proc.stdout if isinstance(proc.stdout, str) else ""


def gh_json(endpoint: str) -> Any:
    out = check(["gh", "api", endpoint])
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid GitHub JSON for {endpoint}: {exc}")


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {path}: {exc}")


def download_asset(repository: str, asset_id: int, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as f:
        proc = subprocess.run(
            ["gh", "api", "-H", "Accept: application/octet-stream", f"repos/{repository}/releases/assets/{asset_id}"],
            check=False,
            stdout=f,
            stderr=subprocess.PIPE,
        )
    if proc.returncode:
        raise SystemExit(f"failed to download prior asset {asset_id}: {proc.stderr.decode(errors='replace').strip()}")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def sha_json(value: Any) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(raw).hexdigest()


def version_sort_key(value: str) -> tuple[tuple[int, Any], ...]:
    parts = re.split(r"[.-]", str(value).lstrip("vV"))
    return tuple((0, int(part)) if part.isdigit() else (1, part.lower()) for part in parts)


def load_results(root: Path) -> dict[str, tuple[dict[str, Any], Path | None]]:
    results: dict[str, tuple[dict[str, Any], Path | None]] = {}
    if not root.exists():
        return results
    for path in root.rglob("result.json"):
        row = load_json(path, {})
        if not isinstance(row, dict) or row.get("schemaVersion") != 1:
            raise SystemExit(f"invalid build result {path}")
        key = str(row.get("key", ""))
        if not key or key in results:
            raise SystemExit(f"invalid or duplicate build result {path}")
        if row.get("skipped") is True or row.get("reused") is True or row.get("failed") is True:
            results[key] = (row, None)
            continue
        asset = path.parent / str(row.get("assetName", ""))
        if not asset.is_file():
            raise SystemExit(f"invalid build result asset {path}")
        if sha256(asset) != str(row.get("sha256", "")).upper():
            raise SystemExit(f"build result digest mismatch: {asset}")
        results[key] = (row, asset)
    return results


def release_exists(repository: str, tag: str) -> bool:
    proc = run(["gh", "release", "view", tag, "--repo", repository])
    return proc.returncode == 0


def release_assets(repository: str, tag: str) -> dict[str, dict[str, Any]]:
    rel = gh_json(f"repos/{repository}/releases/tags/{tag}")
    result = {}
    for asset in rel.get("assets", []):
        if isinstance(asset, dict) and isinstance(asset.get("name"), str):
            result[asset["name"]] = asset
    return result


def accepted_input_id(item: dict[str, Any], version: str) -> str | None:
    candidates = item.get("candidateInputIds")
    if isinstance(candidates, dict):
        value = candidates.get(version)
        if value:
            return str(value)
    base = str(item.get("inputBase", ""))
    if base and int(item.get("forwardProbeLimit", 0) or 0) > 0 and version:
        return sha_json({"base": base, "version": version, "arch": item["arch"], "mode": item["mode"]})
    if version == str(item.get("version", "")):
        return str(item.get("inputId", "")) or None
    return None


def variant_is_compatible(item: dict[str, Any], state: dict[str, Any]) -> bool:
    version = str(state.get("version") or item.get("version", ""))
    expected = accepted_input_id(item, version)
    return bool(expected and state.get("inputId") == expected and isinstance(state.get("assetId"), int))


def compatibility_kind(item: dict[str, Any], version: str) -> str:
    if version == str(item.get("version", "")):
        return "declared-primary"
    candidates = item.get("candidateInputIds")
    if isinstance(candidates, dict) and version in candidates:
        return "declared-fallback"
    return "forward-compatible"


def result_variant_key(row: dict[str, Any]) -> str:
    return str(row.get("variantKey") or row.get("key") or "")


def group_results(results: dict[str, tuple[dict[str, Any], Path | None]]) -> dict[str, list[tuple[str, dict[str, Any], Path | None]]]:
    grouped: dict[str, list[tuple[str, dict[str, Any], Path | None]]] = {}
    for result_key, (row, asset) in results.items():
        grouped.setdefault(result_variant_key(row) or result_key, []).append((result_key, row, asset))
    return grouped


def group_skipped(skipped: dict[str, dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in skipped.values():
        grouped.setdefault(result_variant_key(row), []).append(row)
    return grouped


def reject_aliased_universal_results(
    desired: dict[str, dict[str, Any]],
    successful: dict[str, tuple[dict[str, Any], Path | None]],
    skipped: dict[str, dict[str, Any]],
) -> tuple[dict[str, tuple[dict[str, Any], Path | None]], dict[str, dict[str, Any]]]:
    """Reject byte-identical universal/concrete APK aliases.

    A concrete ABI APK and a real universal APK for the same target/version must
    represent different install sets.  Equal digests mean an upstream
    single-ABI artifact was relabelled as universal somewhere before publication.
    Auto architectures are optional, so suppress the bogus universal result and
    report it as unavailable.  An explicitly-required universal artifact fails
    closed instead of silently publishing a false capability.
    """
    by_identity: dict[tuple[str, str, str], list[tuple[str, dict[str, Any], Path | None]]] = {}
    for result_key, (row, asset) in successful.items():
        identity = (
            str(row.get("target", "")),
            str(row.get("version", "")),
            str(row.get("mode", "")),
        )
        by_identity.setdefault(identity, []).append((result_key, row, asset))

    rejected: set[str] = set()
    updated_skipped = dict(skipped)
    for (target, version, mode), rows in by_identity.items():
        if mode != "apk":
            continue
        universals = [entry for entry in rows if entry[1].get("arch") == "universal"]
        concretes = [entry for entry in rows if entry[1].get("arch") != "universal"]
        for result_key, row, _asset in universals:
            digest = str(row.get("sha256", "")).upper()
            alias = next(
                (entry for entry in concretes if str(entry[1].get("sha256", "")).upper() == digest),
                None,
            )
            if alias is None:
                continue
            concrete_arch = str(alias[1].get("arch", ""))
            variant_key = result_variant_key(row) or result_key
            item = desired.get(variant_key, {})
            reason = (
                f"universal artifact is byte-identical to {concrete_arch}; "
                "single-ABI payload cannot be published as universal"
            )
            if not item.get("optional"):
                raise SystemExit(
                    f"invalid required universal artifact for {target} {version}: {reason}"
                )
            rejected.add(result_key)
            updated_skipped[result_key] = {**row, "skipped": True, "reason": reason}

    return (
        {key: value for key, value in successful.items() if key not in rejected},
        updated_skipped,
    )


def preferred_result(rows: list[tuple[str, dict[str, Any], Path | None]]) -> tuple[str, dict[str, Any], Path | None]:
    return max(rows, key=lambda value: version_sort_key(str(value[1].get("version", ""))))


def write_module_updates(repository: str, tag: str, desired_by_key: dict[str, dict[str, Any]], variants: dict[str, Any], outdir: Path, cache: Path) -> None:
    if not tag.isdigit():
        return
    for key, item in sorted(desired_by_key.items()):
        if item.get("mode") != "module":
            continue
        state = variants.get(key)
        if not isinstance(state, dict) or not variant_is_compatible(item, state):
            continue
        asset_name = str(state.get("assetName", ""))
        local = cache / asset_name
        if not local.exists():
            download_asset(repository, int(state["assetId"]), local)
        try:
            with zipfile.ZipFile(local) as z:
                prop = z.read("module.prop").decode(errors="replace")
        except (zipfile.BadZipFile, KeyError) as exc:
            raise SystemExit(f"could not inspect module.prop in {asset_name}: {exc}")
        values = {}
        for line in prop.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                values[k] = v
        update = values.get("updateJson", "")
        if not update:
            continue
        filename = Path(update).name
        if not filename.endswith("-update.json"):
            continue
        version = values.get("version", "")
        payload = {
            "version": version,
            "versionCode": int(tag),
            "zipUrl": f"https://github.com/{repository}/releases/download/{tag}/{asset_name}",
            "changelog": f"https://raw.githubusercontent.com/{repository}/update/build.md",
        }
        (outdir / filename).write_text(json.dumps(payload, indent=2) + "\n")


def result_or_fallback_ready(
    key: str,
    item: dict[str, Any],
    successful_by_variant: dict[str, list[tuple[str, dict[str, Any], Path | None]]],
    skipped_by_variant: dict[str, list[dict[str, Any]]],
    previous: dict[str, Any],
) -> bool:
    if successful_by_variant.get(key):
        return True
    old = previous.get(key)
    if isinstance(old, dict) and variant_is_compatible(item, old):
        return True
    return bool(item.get("optional") and skipped_by_variant.get(key))


def apply_publication_consistency(
    desired: dict[str, dict[str, Any]],
    successful: dict[str, tuple[dict[str, Any], Path | None]],
    skipped: dict[str, dict[str, Any]],
    previous: dict[str, Any],
) -> tuple[dict[str, tuple[dict[str, Any], Path | None]], dict[str, str]]:
    """Hold new results when configured publication groups are incomplete.

    Multiple successful versions of the same base variant count as one ready
    member for consistency purposes; if the group is publishable all of those
    versions are allowed through.
    """
    successful_by_variant = group_results(successful)
    skipped_by_variant = group_skipped(skipped)
    held: dict[str, str] = {}
    by_target: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    for key, item in desired.items():
        by_target.setdefault(str(item.get("target", "")), []).append((key, item))

    blocked_targets: set[str] = set()
    for target, items in by_target.items():
        if not any(str(item.get("publishConsistency", "variant")) == "target" for _, item in items):
            continue
        if any(
            not item.get("optional")
            and not result_or_fallback_ready(key, item, successful_by_variant, skipped_by_variant, previous)
            for key, item in items
        ):
            blocked_targets.add(target)

    global_enabled = any(str(item.get("publishConsistency", "variant")) == "global" for item in desired.values())
    global_blocked = global_enabled and any(
        not item.get("optional")
        and not result_or_fallback_ready(key, item, successful_by_variant, skipped_by_variant, previous)
        for key, item in desired.items()
    )

    allowed: dict[str, tuple[dict[str, Any], Path | None]] = {}
    for result_key, value in successful.items():
        variant_key = result_variant_key(value[0]) or result_key
        item = desired[variant_key]
        policy = str(item.get("publishConsistency", "variant"))
        target = str(item.get("target", ""))
        if policy == "global" and global_blocked:
            held[variant_key] = "global publication group is incomplete"
        elif policy == "target" and target in blocked_targets:
            held[variant_key] = f"target publication group {target!r} is incomplete"
        else:
            allowed[result_key] = value
    return allowed, held


def state_entry(item: dict[str, Any], row: dict[str, Any], asset: dict[str, Any], tag: str) -> dict[str, Any]:
    version = str(row.get("version") or item.get("version", ""))
    return {
        "inputId": row["inputId"],
        "target": item["target"],
        "arch": item["arch"],
        "mode": item["mode"],
        "version": version,
        "compatibility": compatibility_kind(item, version),
        "assetId": asset["id"],
        "assetName": row["assetName"],
        "sha256": str(row.get("sha256", "")).upper(),
        "releaseTag": tag,
    }


def pending_details(
    pending: list[str],
    desired: dict[str, dict[str, Any]],
    failed_results: dict[str, dict[str, Any]],
    held: dict[str, str],
) -> list[dict[str, Any]]:
    failed_by_variant: dict[str, list[dict[str, Any]]] = {}
    for row in failed_results.values():
        failed_by_variant.setdefault(result_variant_key(row), []).append(row)
    details: list[dict[str, Any]] = []
    for key in sorted(pending):
        item = desired.get(key, {})
        failures = failed_by_variant.get(key, [])
        if key in held:
            reason = held[key]
            category = "publication-held"
        elif failures:
            reason = str(failures[0].get("reason") or "build candidate failed")
            category = "build-failed"
        else:
            reason = "no successful package result was produced"
            category = "no-result"
        details.append({
            "key": key,
            "target": str(item.get("target", "")),
            "arch": str(item.get("arch", "")),
            "mode": str(item.get("mode", "")),
            "version": str(item.get("version", "")),
            "optional": bool(item.get("optional", False)),
            "category": category,
            "reason": reason,
        })
    return details


def write_publication_status(
    outdir: Path,
    *,
    repository: str,
    tag: str,
    generation: str,
    pending: list[str],
    pending_detail_rows: list[dict[str, Any]],
    held: dict[str, str],
    published_assets: list[dict[str, Any]],
) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    status = {
        "schemaVersion": 1,
        "releaseTag": tag,
        "generation": generation,
        "complete": not pending,
        "pending": sorted(pending),
        "pendingDetails": pending_detail_rows,
        "held": {key: held[key] for key in sorted(held)},
        "publishedAssetCount": len(published_assets),
    }
    (outdir / "publication-status.json").write_text(
        json.dumps(status, indent=2, sort_keys=True) + "\n"
    )
    (outdir / "published-assets.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "repository": repository,
                "releaseTag": tag,
                "assets": published_assets,
            },
            indent=2,
            sort_keys=True,
        ) + "\n"
    )


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--plan", type=Path, required=True)
    p.add_argument("--state", type=Path, required=True)
    p.add_argument("--artifacts", type=Path, required=True)
    p.add_argument("--output-dir", type=Path, required=True)
    a = p.parse_args()

    plan = load_json(a.plan, {})
    if not isinstance(plan, dict) or plan.get("schemaVersion") != 1:
        raise SystemExit("unsupported plan schema")
    repository = str(plan.get("repository", ""))
    tag = str(plan.get("releaseTag", ""))
    generation = str(plan.get("generation", ""))
    if not repository or not tag or not generation:
        raise SystemExit("incomplete plan")

    state = load_json(a.state, {"schemaVersion": 1, "variants": {}})
    if not isinstance(state, dict) or state.get("schemaVersion") != 1 or not isinstance(state.get("variants"), dict):
        raise SystemExit("unsupported build state")
    previous = dict(state.get("variants", {}))
    desired = {str(x["key"]): x for x in plan.get("desired", []) if isinstance(x, dict) and x.get("key")}
    results = load_results(a.artifacts)

    for result_key, (row, _asset) in results.items():
        variant_key = result_variant_key(row)
        item = desired.get(variant_key)
        version = str(row.get("version") or item.get("version", "") if item else "")
        expected = accepted_input_id(item, version) if item is not None else None
        if item is None or not expected or row.get("inputId") != expected:
            raise SystemExit(f"build result does not match the current plan: {result_key}")
        if row.get("target") != item.get("target") or row.get("arch") != item.get("arch") or row.get("mode") != item.get("mode"):
            raise SystemExit(f"build result variant axes do not match the current plan: {result_key}")
        if row.get("skipped") is True and not item.get("optional"):
            raise SystemExit(f"required build variant was incorrectly reported as skipped: {result_key}")
        if row.get("reused") is True and not isinstance(row.get("sourceAssetId"), int):
            raise SystemExit(f"reused build result has no source asset: {result_key}")

    successful = {
        key: value for key, value in results.items()
        if value[0].get("skipped") is not True and value[0].get("failed") is not True
    }
    skipped = {key: value[0] for key, value in results.items() if value[0].get("skipped") is True}
    failed_results = {key: value[0] for key, value in results.items() if value[0].get("failed") is True}
    successful, skipped = reject_aliased_universal_results(desired, successful, skipped)
    successful, held = apply_publication_consistency(desired, successful, skipped, previous)
    successful_by_variant = group_results(successful)
    skipped_by_variant = group_skipped(skipped)

    provisional_pending = [
        key
        for key, item in desired.items()
        if not item.get("optional")
        and not result_or_fallback_ready(key, item, successful_by_variant, skipped_by_variant, previous)
    ]

    # A release cannot store two different payloads under one asset name. Catch
    # this before --clobber could silently replace another successful version.
    asset_digests: dict[str, str] = {}
    for result_key, (row, _asset) in successful.items():
        name = str(row.get("assetName", ""))
        digest = str(row.get("sha256", "")).upper()
        if not name:
            raise SystemExit(f"successful build result has no asset name: {result_key}")
        old_digest = asset_digests.get(name)
        if old_digest is not None and old_digest != digest:
            raise SystemExit(f"multiple successful versions produced conflicting release asset name: {name}")
        asset_digests[name] = digest

    same_release = state.get("generation") == generation and str(state.get("releaseTag", "")) == tag
    if not successful and not same_release:
        print("No successful build results exist for the new generation. Keep the current build state.")
        a.output_dir.mkdir(parents=True, exist_ok=True)
        (a.output_dir / "reconciled.json").write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
        write_publication_status(
            a.output_dir,
            repository=repository,
            tag=tag,
            generation=generation,
            pending=provisional_pending,
            pending_detail_rows=pending_details(provisional_pending, desired, failed_results, held),
            held=held,
            published_assets=[],
        )
        return

    a.output_dir.mkdir(parents=True, exist_ok=True)
    cache = a.output_dir / "assets"
    cache.mkdir(exist_ok=True)
    marker = f"<!-- patched-kushion-generation:{generation} -->"
    existed = release_exists(repository, tag)
    if not existed:
        check(["gh", "release", "create", tag, "--repo", repository, "--title", "Release", "--notes", f"{marker}\nBuild publication is in progress."])
    existing_before = release_assets(repository, tag)

    # On a new generation retain one known-good previous asset per base variant
    # only when this run has no compatible result for that variant. It remains a
    # stale fallback and therefore does not suppress rebuilding the new patch set.
    if not same_release:
        for key, item in desired.items():
            if successful_by_variant.get(key):
                continue
            old = previous.get(key)
            if not isinstance(old, dict) or not isinstance(old.get("assetId"), int) or not old.get("assetName"):
                continue
            if str(old["assetName"]) in existing_before:
                continue
            local = cache / str(old["assetName"])
            download_asset(repository, int(old["assetId"]), local)
            check(["gh", "release", "upload", tag, str(local), "--repo", repository, "--clobber"])

    current_names = set(release_assets(repository, tag))
    published_result_keys: set[str] = set()
    for result_key, (row, asset) in sorted(successful.items()):
        asset_name = str(row["assetName"])
        if asset_name in current_names:
            # Existing same-generation assets are immutable by input identity;
            # a new local payload is still checked below by the final state hash.
            if row.get("reused") is True:
                continue
        if row.get("reused") is True:
            local = cache / asset_name
            download_asset(repository, int(row["sourceAssetId"]), local)
            if row.get("sha256") and sha256(local) != str(row["sha256"]).upper():
                raise SystemExit(f"reused build result digest mismatch: {result_key}")
            check(["gh", "release", "upload", tag, str(local), "--repo", repository, "--clobber"])
            current_names.add(asset_name)
            published_result_keys.add(result_key)
            continue
        assert asset is not None
        check(["gh", "release", "upload", tag, str(asset), "--repo", repository, "--clobber"])
        shutil.copyfile(asset, cache / asset.name)
        current_names.add(asset_name)
        published_result_keys.add(result_key)

    assets = release_assets(repository, tag)
    published_assets: list[dict[str, Any]] = []
    for result_key in sorted(published_result_keys):
        row = successful[result_key][0]
        variant_key = result_variant_key(row) or result_key
        item = desired[variant_key]
        asset = assets.get(str(row["assetName"]))
        if not isinstance(asset, dict) or not isinstance(asset.get("id"), int):
            raise SystemExit(f"published release asset missing from manifest: {row['assetName']}")
        size = asset.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise SystemExit(f"published release asset has no valid size: {row['assetName']}")
        published_assets.append({
            "resultKey": result_key,
            "variantKey": variant_key,
            "target": item["target"],
            "arch": item["arch"],
            "mode": item["mode"],
            "version": str(row.get("version") or item.get("version", "")),
            "assetId": asset["id"],
            "assetName": asset["name"],
            "size": size,
        })

    # Keep every successful input in a reuse ledger. The planner only accepts
    # entries whose asset id/name still exists in this exact release, making the
    # ledger self-healing when a release asset is manually removed.
    artifact_index: dict[str, Any] = {}
    if same_release and isinstance(state.get("artifactsByInputId"), dict):
        for input_id, entry in state["artifactsByInputId"].items():
            if not isinstance(entry, dict) or str(entry.get("inputId", "")) != str(input_id):
                continue
            asset_id = entry.get("assetId")
            asset_name = str(entry.get("assetName", ""))
            asset = assets.get(asset_name)
            if isinstance(asset_id, int) and asset and asset.get("id") == asset_id:
                artifact_index[str(input_id)] = entry

    for variant_key, rows in successful_by_variant.items():
        item = desired[variant_key]
        for _result_key, row, _local in rows:
            asset = assets.get(str(row["assetName"]))
            if not asset or not isinstance(asset.get("id"), int):
                raise SystemExit(f"uploaded release asset missing: {row['assetName']}")
            entry = state_entry(item, row, asset, tag)
            existing = artifact_index.get(str(row["inputId"]))
            if isinstance(existing, dict) and existing.get("sha256") and existing.get("sha256") != entry.get("sha256"):
                raise SystemExit(f"one input identity produced multiple payload digests: {row['inputId']}")
            artifact_index[str(row["inputId"])] = entry

    new_variants: dict[str, Any] = {}
    for key, item in desired.items():
        rows = successful_by_variant.get(key, [])
        old = previous.get(key)
        if rows:
            _result_key, row, _local = preferred_result(rows)
            asset = assets.get(str(row["assetName"]))
            if not asset or not isinstance(asset.get("id"), int):
                raise SystemExit(f"uploaded release asset missing: {row['assetName']}")
            new_variants[key] = state_entry(item, row, asset, tag)
        elif isinstance(old, dict) and old.get("assetName") in assets:
            copied = assets[str(old["assetName"])]
            new_variants[key] = {**old, "assetId": copied["id"], "assetName": copied["name"], "releaseTag": tag}
        elif same_release and isinstance(old, dict):
            new_variants[key] = old

    primary: list[str] = []
    fallback: list[str] = []
    forward: list[str] = []
    unavailable: list[str] = []
    pending: list[str] = []
    for key, item in desired.items():
        row = new_variants.get(key, {})
        if isinstance(row, dict) and variant_is_compatible(item, row):
            kind = compatibility_kind(item, str(row.get("version", "")))
            if kind == "declared-primary":
                primary.append(key)
            elif kind == "declared-fallback":
                fallback.append(key)
            else:
                forward.append(key)
        elif item.get("optional") and skipped_by_variant.get(key):
            unavailable.append(key)
        else:
            pending.append(key)

    write_publication_status(
        a.output_dir,
        repository=repository,
        tag=tag,
        generation=generation,
        pending=pending,
        pending_detail_rows=pending_details(pending, desired, failed_results, held),
        held=held,
        published_assets=published_assets,
    )

    new_state = {
        "schemaVersion": 1,
        "generation": generation,
        "releaseTag": tag,
        "complete": not pending,
        "variants": new_variants,
        "artifactsByInputId": artifact_index,
        "fallback": {
            key: {"version": new_variants[key].get("version", ""), "inputId": new_variants[key].get("inputId", "")}
            for key in fallback
        },
        "forwardCompatible": {
            key: {"version": new_variants[key].get("version", ""), "inputId": new_variants[key].get("inputId", "")}
            for key in forward
        },
        "unavailable": {
            key: {
                "inputId": desired[key]["inputId"],
                "reason": str(skipped_by_variant[key][0].get("reason", "stock variant unavailable")),
            }
            for key in unavailable
        },
        "held": {key: {"inputId": desired[key]["inputId"], "reason": reason} for key, reason in held.items()},
    }
    (a.output_dir / "build-state.json").write_text(json.dumps(new_state, indent=2, sort_keys=True) + "\n")
    (a.output_dir / "reconciled.json").write_text(json.dumps(new_state, indent=2, sort_keys=True) + "\n")

    lines = [marker, f"# Release {tag}", "", f"Generation: `{generation}`", "", "## Preferred declared variants", ""]
    lines += [f"- {key}" for key in primary] or ["- None"]
    lines += ["", "## Preferred forward-compatible variants", ""]
    lines += [f"- {key}: `{new_variants[key].get('version', '')}`" for key in forward] or ["- None"]
    lines += ["", "## Compatible fallback variants", ""]
    lines += [f"- {key}: `{new_variants[key].get('version', '')}`" for key in fallback] or ["- None"]
    lines += ["", "## Auto variants unavailable from current stock sources", ""]
    lines += [f"- {key}: {skipped_by_variant[key][0].get('reason', 'stock variant unavailable')}" for key in unavailable] or ["- None"]
    lines += ["", "## Held by publication policy", ""]
    lines += [f"- {key}: {held[key]}" for key in sorted(held)] or ["- None"]
    lines += ["", "## Pending retry", ""] + ([f"- {key}" for key in pending] or ["- None"])
    if successful:
        lines += ["", "## Compatible assets published this run", ""]
        for result_key, (row, _) in sorted(successful.items()):
            variant_key = result_variant_key(row)
            lines.append(f"- {variant_key} @ `{row.get('version', '')}`: `{row['assetName']}` ({result_key})")
    (a.output_dir / "build.md").write_text("\n".join(lines) + "\n")

    write_module_updates(repository, tag, desired, new_variants, a.output_dir, cache)
    release_state_asset = a.output_dir / "patched-kushion-build-state.json"
    shutil.copyfile(a.output_dir / "build-state.json", release_state_asset)
    check(["gh", "release", "upload", tag, str(release_state_asset), "--repo", repository, "--clobber"])
    check(["gh", "release", "edit", tag, "--repo", repository, "--notes-file", str(a.output_dir / "build.md")])
    print(f"release_tag={tag}")
    print(f"primary={len(primary)}")
    print(f"forward_compatible={len(forward)}")
    print(f"fallback={len(fallback)}")
    print(f"reusable_inputs={len(artifact_index)}")
    print(f"unavailable={len(unavailable)}")
    print(f"held={len(held)}")
    print(f"pending={len(pending)}")


if __name__ == "__main__":
    main()
