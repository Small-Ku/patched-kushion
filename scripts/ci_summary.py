#!/usr/bin/env python3
"""Render compact GitHub Actions summaries from patched-kushion handoff metadata.

The build pipeline intentionally keeps verbose diagnostics in artifacts.  This
module turns the small JSON handoffs into human-readable job summaries so the
normal Actions UI answers "what happened?" without requiring log archaeology.
"""
from __future__ import annotations

import argparse
import json
import os
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


def load_json(path: Path | None, default: Any = None) -> Any:
    if path is None or not path.is_file():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON {path}: {exc}")


def all_json(root: Path | None, name: str) -> list[dict[str, Any]]:
    if root is None or not root.exists():
        return []
    rows: list[dict[str, Any]] = []
    for path in sorted(root.rglob(name)):
        value = load_json(path, {})
        if isinstance(value, dict):
            value = dict(value)
            value.setdefault("_path", str(path))
            rows.append(value)
    return rows


def esc(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def code(value: Any) -> str:
    text = str(value) if value not in (None, "") else "—"
    return f"`{text.replace('`', "'")}`"


def bytes_text(value: Any) -> str:
    try:
        size = int(value)
    except (TypeError, ValueError):
        return "—"
    units = ["B", "KiB", "MiB", "GiB"]
    current = float(size)
    unit = units[0]
    for unit in units:
        if current < 1024 or unit == units[-1]:
            break
        current /= 1024
    return f"{current:.2f} {unit}" if unit != "B" else f"{size} B"


def table(headers: list[str], rows: Iterable[Iterable[Any]]) -> list[str]:
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        out.append("| " + " | ".join(esc(cell) for cell in row) + " |")
    return out


def emit(markdown: str, *, output: Path | None = None, append_github: bool = True) -> None:
    markdown = markdown.rstrip() + "\n"
    print(markdown, end="")
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(markdown, encoding="utf-8")
    summary = os.environ.get("GITHUB_STEP_SUMMARY") if append_github else None
    if summary:
        with Path(summary).open("a", encoding="utf-8") as handle:
            handle.write(markdown)


def plan_markdown(plan: dict[str, Any]) -> str:
    desired = [x for x in plan.get("desired", []) if isinstance(x, dict)]
    matrix = [x for x in plan.get("matrix", []) if isinstance(x, dict)]
    availability = [x for x in plan.get("availability", []) if isinstance(x, dict)]
    satisfied = sum(bool(x.get("satisfied")) for x in desired)
    optional = sum(bool(x.get("optional")) for x in desired)
    lines = [
        "## Build plan",
        "",
        f"Release {code(plan.get('releaseTag'))} · generation {code(str(plan.get('generation', ''))[:12])} · "
        f"{len(availability)} target(s) · {len(desired)} desired variant(s) · {len(matrix)} scheduled · {satisfied} already satisfied · {optional} opportunistic.",
        "",
    ]
    rows = []
    for row in availability:
        rows.append([
            row.get("target", ""),
            ", ".join(map(str, row.get("versionCandidates", []))) or row.get("version", ""),
            row.get("archPolicy", "explicit"),
            ", ".join(map(str, row.get("availableArches", []))) or "—",
            ", ".join(map(str, row.get("optionalArches", []))) or "—",
        ])
    lines += table(["Target", "Version candidates", "Arch policy", "Planned outputs", "Opportunistic"], rows)
    return "\n".join(lines)


def source_markdown(status: dict[str, Any], source: dict[str, Any] | None) -> str:
    target = status.get("target", "Source")
    version = status.get("version", "")
    ready = bool(status.get("ready"))
    outcome = status.get("acquisitionOutcome", "unknown")
    category = str(status.get("category") or "")
    reason = str(status.get("reason") or "")
    diagnostics = status.get("diagnostics") if isinstance(status.get("diagnostics"), dict) else {}
    lines = [f"## Source · {target} {version}", ""]
    if source:
        providers = source.get("sources") or ([source.get("sourceName")] if source.get("sourceName") else [])
        lines += [
            f"**{'Ready' if ready else 'Unavailable'}** · outcome {code(outcome)} · strategy {code(source.get('strategy', status.get('strategy', '')))}"
            f" · provider(s) {code(', '.join(map(str, providers)) if providers else 'none')}",
            "",
            f"Available build outputs: {', '.join(map(str, source.get('availableBuildArches', []))) or 'none'}.",
        ]
        missing = source.get("coverage", {}).get("missingDesired", []) if isinstance(source.get("coverage"), dict) else []
        if missing:
            lines.append(f"Missing opportunistic outputs: {', '.join(map(str, missing))}.")
    else:
        exit_code = status.get("exitCode") or "—"
        lines.append(f"**Unavailable** · outcome {code(outcome)} · acquisition exit {code(exit_code)}. Full diagnostics are in the source metadata artifact.")
    if not ready and reason:
        lines += ["", f"Failure: {code(category or 'source-unavailable')} · {reason}"]
    provider_attempts = [x for x in diagnostics.get("providerAttempts", []) if isinstance(x, dict)]
    if provider_attempts:
        lines += ["", "### Provider attempts", ""]
        lines += table(
            ["Provider", "Arch", "Status", "Category", "HTTP", "Reason"],
            ([x.get("provider", ""), x.get("arch", "") or "shared", x.get("status", ""), x.get("category", ""), x.get("httpStatus", ""), x.get("reason", "")] for x in provider_attempts),
        )
    return "\n".join(lines)


def stage_markdown(title: str, status: dict[str, Any], metadata: dict[str, Any] | None = None) -> str:
    state = str(status.get("status", "unknown"))
    outcome = str(status.get("outcome", state))
    reason = str(status.get("reason", ""))
    category = str(status.get("category") or "")
    failure_class = str(status.get("failureClass") or "")
    compatibility = str(status.get("compatibility") or "")
    axes = " / ".join(str(status.get(x, "")) for x in ("target", "version", "arch", "mode") if status.get(x))
    headline = f"**{state}** · outcome {code(outcome)}"
    if category:
        headline += f" · category {code(category)}"
    if failure_class:
        headline += f" · class {code(failure_class)}"
    if compatibility:
        headline += f" · compatibility {code(compatibility)}"
    if reason:
        headline += f" · {reason}"
    lines = [f"## {title} · {axes}", "", headline]
    if metadata:
        extra = []
        if metadata.get("sourceName"):
            extra.append(f"source={metadata['sourceName']}")
        if metadata.get("sha256"):
            extra.append(f"sha256={str(metadata['sha256'])[:12]}…")
        if extra:
            lines += ["", " · ".join(extra)]
    diagnostics = status.get("diagnostics") if isinstance(status.get("diagnostics"), dict) else {}
    patch_name = str(diagnostics.get("patch") or "")
    dependency = str(diagnostics.get("dependency") or "")
    root = diagnostics.get("rootCause") if isinstance(diagnostics.get("rootCause"), dict) else {}
    if patch_name or dependency or root:
        lines += ["", "Diagnostic root cause:"]
        if patch_name:
            lines.append(f"- Patch: {code(patch_name)}")
        if dependency:
            lines.append(f"- Dependency: {code(dependency)}")
        if root:
            root_text = str(root.get("type") or "exception").rsplit(".", 1)[-1]
            if root.get("message"):
                root_text += f": {root['message']}"
            if root.get("location"):
                root_text += f" at {root['location']}"
            lines.append(f"- Root cause: {code(root_text)}")
    evidence = [str(x) for x in diagnostics.get("evidence", []) if str(x).strip()]
    if evidence:
        lines += ["", "Diagnostic evidence:"] + [f"- {code(x)}" for x in evidence[:5]]
    return "\n".join(lines)


def variant_markdown(row: dict[str, Any]) -> str:
    state = str(row.get("status") or ("failed" if row.get("failed") else "skipped" if row.get("skipped") else "reused" if row.get("reused") else "ready"))
    headline = f"**{state}**"
    if row.get("category"):
        headline += f" · category {code(row.get('category'))}"
    if row.get("compatibility"):
        headline += f" · compatibility {code(row.get('compatibility'))}"
    if row.get("reason"):
        headline += f" · {row.get('reason')}"
    lines = [
        f"## Variant · {row.get('target','')} / {row.get('version','')} / {row.get('arch','')} / {row.get('mode','')}",
        "",
        headline,
    ]
    if row.get("assetName"):
        lines.append(f"Asset: {code(row['assetName'])} · SHA-256 {code(str(row.get('sha256',''))[:12] + '…')}")
    return "\n".join(lines)


def release_markdown(plan: dict[str, Any], status: dict[str, Any], assets: dict[str, Any]) -> str:
    published = [x for x in assets.get("assets", []) if isinstance(x, dict)] if isinstance(assets, dict) else []
    pending = [x for x in status.get("pendingDetails", []) if isinstance(x, dict)] if isinstance(status, dict) else []
    lines = [
        "## Release publication",
        "",
        f"Release {code(status.get('releaseTag', plan.get('releaseTag', '')))} · "
        f"{len(published)} newly published asset(s) · {len(pending)} required variant(s) pending · "
        f"complete={code(str(bool(status.get('complete', False))).lower())}.",
    ]
    if published:
        lines += ["", "### New assets", ""]
        lines += table(
            ["Target", "Version", "Arch", "Mode", "Asset", "Size"],
            ([x.get("target", ""), x.get("version", ""), x.get("arch", ""), x.get("mode", ""), x.get("assetName", ""), bytes_text(x.get("size"))] for x in published),
        )
    if pending:
        lines += ["", "### Pending required variants", ""]
        lines += table(
            ["Target", "Requirement", "Best candidate", "Arch", "Mode", "Category", "Reason"],
            ([
                x.get("target", ""),
                x.get("version", ""),
                (str(x.get("attemptedVersion", "")) + (f" ({x.get('attemptedCompatibility')})" if x.get("attemptedCompatibility") else "")) or "—",
                x.get("arch", ""),
                x.get("mode", ""),
                x.get("category", ""),
                x.get("reason", ""),
            ] for x in pending),
        )
    return "\n".join(lines)


def provenance_records(value: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not isinstance(value, dict):
        return []
    return [x for x in value.get("packages", []) if isinstance(x, dict)]


def provenance_key(row: dict[str, Any]) -> tuple[str, str, int]:
    try:
        asset_id = int(row.get("assetId", -1))
    except (TypeError, ValueError):
        asset_id = -1
    return (str(row.get("source", "")), str(row.get("repository", "")), asset_id)


def fdroid_delta(before: dict[str, Any] | None, after: dict[str, Any] | None) -> dict[str, Any]:
    old = {provenance_key(x): x for x in provenance_records(before)}
    new = {provenance_key(x): x for x in provenance_records(after)}
    added = [new[k] for k in sorted(new.keys() - old.keys())]
    removed = [old[k] for k in sorted(old.keys() - new.keys())]
    packages = provenance_records(after)
    return {"beforeCount": len(old), "afterCount": len(new), "added": added, "removed": removed, "packages": packages}


def fdroid_markdown(delta: dict[str, Any]) -> str:
    lines = [
        "## F-Droid repository",
        "",
        f"{delta.get('afterCount', 0)} provenance record(s) after sync · +{len(delta.get('added', []))} / -{len(delta.get('removed', []))} this run.",
    ]
    if delta.get("added"):
        lines += ["", "### Added", ""]
        lines += table(
            ["Package", "Version", "Native code", "Release asset", "Size"],
            ([x.get("packageName", ""), x.get("versionName") or x.get("versionCode", ""), ", ".join(x.get("nativeCodes", [])) or "universal/noarch", x.get("assetName", ""), bytes_text(x.get("assetSize"))] for x in delta["added"]),
        )
    if delta.get("removed"):
        lines += ["", "### Removed", ""]
        lines += table(
            ["Package", "Version", "Release asset"],
            ([x.get("packageName", ""), x.get("versionName") or x.get("versionCode", ""), x.get("assetName", "")] for x in delta["removed"]),
        )
    return "\n".join(lines)


def int_value(value: Any, default: int = 1_000_000) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


ATTEMPT_STAGE_RANK = {"source": 0, "build": 1, "stock": 1, "patch": 2, "package": 3}


def best_progress_attempt(attempts: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not attempts:
        return None
    return max(
        attempts,
        key=lambda row: (
            ATTEMPT_STAGE_RANK.get(str(row.get("stage", "")), 0),
            -int_value(row.get("traversalIndex")),
        ),
    )


def candidate_attempt_history(
    item: dict[str, Any],
    source_rows: list[dict[str, Any]],
    result_rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    target = str(item.get("target", ""))
    variant_key = str(item.get("key", ""))
    arch = str(item.get("arch", ""))
    sources = {
        str(row.get("version", "")): row
        for row in source_rows
        if str(row.get("target", "")) == target and row.get("version")
    }
    results_by_version: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in result_rows:
        if str(row.get("variantKey") or row.get("key") or "") == variant_key and row.get("version"):
            results_by_version[str(row.get("version"))].append(row)

    versions = set(sources) | set(results_by_version)
    attempts: list[dict[str, Any]] = []
    for version in versions:
        source = sources.get(version)
        results = results_by_version.get(version, [])
        failed = [row for row in results if row.get("failed") is True]
        if failed:
            row = sorted(failed, key=lambda value: int_value(value.get("traversalIndex")))[0]
            attempts.append({
                "version": version,
                "compatibility": str(row.get("compatibility") or (source or {}).get("compatibility") or ""),
                "traversalIndex": int_value(row.get("traversalIndex", (source or {}).get("traversalIndex"))),
                "stage": str(row.get("stage") or "patch"),
                "category": str(row.get("category") or "build-failed"),
                "failureClass": str(row.get("failureClass") or ""),
                "reason": str(row.get("reason") or "build candidate failed"),
            })
            continue
        if source and not bool(source.get("ready")):
            diagnostics = source.get("diagnostics") if isinstance(source.get("diagnostics"), dict) else {}
            provider_rows = [x for x in diagnostics.get("providerAttempts", []) if isinstance(x, dict)]
            relevant = [x for x in provider_rows if not x.get("arch") or str(x.get("arch")) == arch]
            provider_summary = "; ".join(
                f"{x.get('provider', 'source')}:{x.get('category', 'unavailable')}"
                for x in relevant[:5]
            )
            attempts.append({
                "version": version,
                "compatibility": str(source.get("compatibility") or ""),
                "traversalIndex": int_value(source.get("traversalIndex")),
                "stage": "source",
                "category": str(source.get("category") or "source-unavailable"),
                "failureClass": str(diagnostics.get("failureClass") or "source"),
                "reason": str(source.get("reason") or "source candidate did not become ready"),
                "providers": provider_summary,
            })
            continue
        if source and bool(source.get("ready")) and not results:
            attempts.append({
                "version": version,
                "compatibility": str(source.get("compatibility") or ""),
                "traversalIndex": int_value(source.get("traversalIndex")),
                "stage": "build",
                "category": "no-result",
                "failureClass": "unknown",
                "reason": "source became ready but no package result was recorded for this requirement",
            })
    attempts.sort(key=lambda row: (int_value(row.get("traversalIndex")), str(row.get("version", ""))))
    return attempts


def pipeline_summary(
    plan: dict[str, Any],
    source_rows: list[dict[str, Any]],
    result_rows: list[dict[str, Any]],
    publication: dict[str, Any] | None,
    assets: dict[str, Any] | None,
    fdroid: dict[str, Any] | None,
    job_results: dict[str, str],
    fdroid_changed: str,
) -> tuple[dict[str, Any], str]:
    desired = [x for x in plan.get("desired", []) if isinstance(x, dict)]
    published = [x for x in (assets or {}).get("assets", []) if isinstance(x, dict)]
    pending_details = [x for x in (publication or {}).get("pendingDetails", []) if isinstance(x, dict)]
    pending_keys = set((publication or {}).get("pending", []))
    result_by_variant: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in result_rows:
        result_by_variant[str(row.get("variantKey") or row.get("key") or "")].append(row)

    counts: Counter[str] = Counter()
    variant_rows: list[dict[str, Any]] = []
    for item in desired:
        key = str(item.get("key", ""))
        rows = result_by_variant.get(key, [])
        if key in pending_keys:
            state = "pending"
        elif any(r.get("failed") is True for r in rows):
            state = "failed"
        elif any(r.get("skipped") is True for r in rows):
            state = "unavailable"
        elif any(r.get("reused") is True for r in rows):
            state = "reused"
        elif rows:
            state = "built"
        elif item.get("satisfied"):
            state = "current"
        elif item.get("optional"):
            state = "not-observed"
        else:
            state = "missing"
        counts[state] += 1
        variant_rows.append({"key": key, "target": item.get("target"), "arch": item.get("arch"), "mode": item.get("mode"), "version": item.get("version"), "state": state})

    failed_sources = [r for r in source_rows if not bool(r.get("ready"))]
    desired_by_key = {str(item.get("key", "")): item for item in desired}
    enriched_pending: list[dict[str, Any]] = []
    pending_attempt_rows: list[dict[str, Any]] = []
    for raw in pending_details:
        detail = dict(raw)
        item = desired_by_key.get(str(detail.get("key", "")), detail)
        attempts = candidate_attempt_history(item, source_rows, result_rows)
        detail["candidateAttempts"] = attempts
        best = best_progress_attempt(attempts)
        if best is not None:
            if not detail.get("attemptedVersion"):
                detail["attemptedVersion"] = best.get("version", "")
                detail["attemptedCompatibility"] = best.get("compatibility", "")
            detail["blockingStage"] = best.get("stage", "")
            if str(detail.get("category") or "") in {"", "no-result", "build-failed"} and best.get("category"):
                detail["category"] = best.get("category")
                detail["failureClass"] = best.get("failureClass", "")
                generic_reason = str(detail.get("reason") or "")
                if not generic_reason or generic_reason in {"no successful package result was produced", "build candidate failed"}:
                    detail["reason"] = best.get("reason", generic_reason)
        enriched_pending.append(detail)
        for attempt in attempts:
            pending_attempt_rows.append({
                "key": detail.get("key", ""),
                "target": detail.get("target", item.get("target", "")),
                "requirementVersion": detail.get("version", item.get("version", "")),
                "arch": detail.get("arch", item.get("arch", "")),
                "mode": detail.get("mode", item.get("mode", "")),
                **attempt,
            })

    overall_ok = (
        job_results.get("plan") == "success"
        and job_results.get("build") in {"success", "skipped"}
        and job_results.get("release") == "success"
        and job_results.get("check_fdroid") in {"success", "skipped"}
        and job_results.get("fdroid") in {"success", "skipped"}
        and not pending_keys
    )
    summary = {
        "schemaVersion": 1,
        "releaseTag": plan.get("releaseTag"),
        "generation": plan.get("generation"),
        "ok": overall_ok,
        "jobResults": job_results,
        "fdroidChanged": fdroid_changed,
        "desiredVariantCount": len(desired),
        "variantCounts": dict(sorted(counts.items())),
        "sourceCandidateCount": len(source_rows),
        "failedSourceCandidateCount": len(failed_sources),
        "publishedAssets": published,
        "pending": enriched_pending,
        "pendingAttempts": pending_attempt_rows,
        "variants": variant_rows,
        "fdroid": fdroid or {},
    }

    lines = [
        "# patched-kushion update summary",
        "",
        ("**Publication complete.**" if overall_ok else "**Publication needs attention.**")
        + f" Release {code(plan.get('releaseTag'))} · {len(desired)} desired variant(s) · "
        f"{len(published)} new release asset(s) · {len(pending_keys)} required pending.",
        "",
        "## Workflow status",
        "",
    ]
    lines += table(
        ["Stage", "Result"],
        [["Plan", job_results.get("plan", "unknown")], ["Build matrix", job_results.get("build", "unknown")], ["Release", job_results.get("release", "unknown")], ["F-Droid check", job_results.get("check_fdroid", "unknown")], ["F-Droid publish", job_results.get("fdroid", "unknown")]],
    )
    lines += ["", "## Variant outcomes", ""]
    lines += table(["Outcome", "Count"], [[key, value] for key, value in sorted(counts.items())])

    if published:
        lines += ["", "## Newly published release assets", ""]
        lines += table(
            ["Target", "Version", "Arch", "Mode", "Asset", "Size"],
            ([x.get("target", ""), x.get("version", ""), x.get("arch", ""), x.get("mode", ""), x.get("assetName", ""), bytes_text(x.get("size"))] for x in published),
        )
    if enriched_pending:
        lines += ["", "## Required variants still pending", ""]
        lines += table(
            ["Target", "Requirement", "Best candidate", "Arch", "Mode", "Category", "Reason"],
            ([
                x.get("target", ""),
                x.get("version", ""),
                (str(x.get("attemptedVersion", "")) + (f" ({x.get('attemptedCompatibility')})" if x.get("attemptedCompatibility") else "")) or "—",
                x.get("arch", ""),
                x.get("mode", ""),
                x.get("category", ""),
                x.get("reason", ""),
            ] for x in enriched_pending),
        )
    if pending_attempt_rows:
        lines += ["", "## Candidate attempts for pending requirements", ""]
        lines += table(
            ["Requirement", "Candidate", "Compatibility", "Furthest stage", "Category", "Class", "Reason", "Providers"],
            ([
                f"{x.get('target','')} / {x.get('requirementVersion','')} / {x.get('arch','')} / {x.get('mode','')}",
                x.get("version", ""),
                x.get("compatibility", ""),
                x.get("stage", ""),
                x.get("category", ""),
                x.get("failureClass", ""),
                x.get("reason", ""),
                x.get("providers", ""),
            ] for x in pending_attempt_rows),
        )
    if failed_sources:
        lines += ["", "## Source candidates that did not become ready", ""]
        lines += table(
            ["Target", "Version", "Compatibility", "Category", "Reason", "Exit"],
            ([x.get("target", ""), x.get("version", ""), x.get("compatibility", ""), x.get("category", "") or x.get("acquisitionOutcome", ""), x.get("reason", ""), x.get("exitCode", "")] for x in failed_sources[:30]),
        )
        if len(failed_sources) > 30:
            lines.append(f"\n{len(failed_sources) - 30} additional failed source candidate(s) are retained in diagnostic artifacts.")
    if fdroid:
        lines += ["", "## F-Droid", "", f"Change gate: {code(fdroid_changed)} · provenance records: {fdroid.get('afterCount', 0)} · added {len(fdroid.get('added', []))} · removed {len(fdroid.get('removed', []))}."]
    return summary, "\n".join(lines)


def common_output(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--no-github-summary", action="store_true")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("plan")
    p.add_argument("--plan", type=Path, required=True); common_output(p)
    p = sub.add_parser("source")
    p.add_argument("--status", type=Path, required=True); p.add_argument("--source", type=Path); common_output(p)
    p = sub.add_parser("stock")
    p.add_argument("--status", type=Path, required=True); p.add_argument("--stock", type=Path); common_output(p)
    p = sub.add_parser("patch")
    p.add_argument("--status", type=Path, required=True); common_output(p)
    p = sub.add_parser("variant")
    p.add_argument("--result", type=Path, required=True); common_output(p)
    p = sub.add_parser("release")
    p.add_argument("--plan", type=Path, required=True); p.add_argument("--status", type=Path, required=True); p.add_argument("--assets", type=Path, required=True); common_output(p)
    p = sub.add_parser("fdroid")
    p.add_argument("--before", type=Path); p.add_argument("--after", type=Path, required=True); p.add_argument("--json", type=Path); common_output(p)
    p = sub.add_parser("pipeline")
    p.add_argument("--plan", type=Path, required=True)
    p.add_argument("--source-root", type=Path)
    p.add_argument("--result-root", type=Path)
    p.add_argument("--publication-status", type=Path)
    p.add_argument("--published-assets", type=Path)
    p.add_argument("--fdroid-summary", type=Path)
    p.add_argument("--plan-result", default="unknown")
    p.add_argument("--build-result", default="unknown")
    p.add_argument("--release-result", default="unknown")
    p.add_argument("--fdroid-check-result", default="unknown")
    p.add_argument("--fdroid-result", default="unknown")
    p.add_argument("--fdroid-changed", default="unknown")
    p.add_argument("--json", type=Path, required=True)
    common_output(p)

    args = parser.parse_args()
    append = not args.no_github_summary
    if args.command == "plan":
        emit(plan_markdown(load_json(args.plan, {})), output=args.markdown, append_github=append)
    elif args.command == "source":
        emit(source_markdown(load_json(args.status, {}), load_json(args.source, None)), output=args.markdown, append_github=append)
    elif args.command in {"stock", "patch"}:
        status = load_json(args.status, {})
        metadata = load_json(args.stock, None) if args.command == "stock" else None
        emit(stage_markdown(args.command.capitalize(), status, metadata), output=args.markdown, append_github=append)
    elif args.command == "variant":
        emit(variant_markdown(load_json(args.result, {})), output=args.markdown, append_github=append)
    elif args.command == "release":
        emit(release_markdown(load_json(args.plan, {}), load_json(args.status, {}), load_json(args.assets, {})), output=args.markdown, append_github=append)
    elif args.command == "fdroid":
        delta = fdroid_delta(load_json(args.before, None), load_json(args.after, {}))
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(delta, indent=2, sort_keys=True) + "\n")
        emit(fdroid_markdown(delta), output=args.markdown, append_github=append)
    elif args.command == "pipeline":
        summary, markdown = pipeline_summary(
            load_json(args.plan, {}),
            all_json(args.source_root, "source-status.json"),
            all_json(args.result_root, "result.json"),
            load_json(args.publication_status, None),
            load_json(args.published_assets, None),
            load_json(args.fdroid_summary, None),
            {"plan": args.plan_result, "build": args.build_result, "release": args.release_result, "check_fdroid": args.fdroid_check_result, "fdroid": args.fdroid_result},
            args.fdroid_changed,
        )
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        emit(markdown, output=args.markdown, append_github=append)


if __name__ == "__main__":
    main()
