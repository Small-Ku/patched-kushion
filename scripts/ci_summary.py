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
    lines = [f"## Source · {target} {version}", ""]
    if source:
        providers = source.get("sources") or ([source.get("sourceName")] if source.get("sourceName") else [])
        lines += [
            f"**{'Ready' if ready else 'Unavailable'}** · outcome {code(outcome)} · strategy {code(source.get('strategy', status.get('strategy', '')))}"
            f" · provider(s) {code(', '.join(map(str, providers)) if providers else 'unknown')}",
            "",
            f"Available build outputs: {', '.join(map(str, source.get('availableBuildArches', []))) or 'none'}.",
        ]
        missing = source.get("coverage", {}).get("missingDesired", []) if isinstance(source.get("coverage"), dict) else []
        if missing:
            lines.append(f"Missing opportunistic outputs: {', '.join(map(str, missing))}.")
    else:
        exit_code = status.get("exitCode") or "—"
        lines.append(f"**Unavailable** · outcome {code(outcome)} · acquisition exit {code(exit_code)}. Full diagnostics are in the source metadata artifact.")
    return "\n".join(lines)


def stage_markdown(title: str, status: dict[str, Any], metadata: dict[str, Any] | None = None) -> str:
    state = str(status.get("status", "unknown"))
    outcome = str(status.get("outcome", state))
    reason = str(status.get("reason", ""))
    axes = " / ".join(str(status.get(x, "")) for x in ("target", "version", "arch", "mode") if status.get(x))
    lines = [f"## {title} · {axes}", "", f"**{state}** · outcome {code(outcome)}" + (f" · {reason}" if reason else "")]
    if metadata:
        extra = []
        if metadata.get("sourceName"):
            extra.append(f"source={metadata['sourceName']}")
        if metadata.get("sha256"):
            extra.append(f"sha256={str(metadata['sha256'])[:12]}…")
        if extra:
            lines += ["", " · ".join(extra)]
    return "\n".join(lines)


def variant_markdown(row: dict[str, Any]) -> str:
    state = str(row.get("status") or ("failed" if row.get("failed") else "skipped" if row.get("skipped") else "reused" if row.get("reused") else "ready"))
    lines = [
        f"## Variant · {row.get('target','')} / {row.get('version','')} / {row.get('arch','')} / {row.get('mode','')}",
        "",
        f"**{state}**" + (f" · {row.get('reason')}" if row.get("reason") else ""),
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
            ["Target", "Version", "Arch", "Mode", "Category", "Reason"],
            ([x.get("target", ""), x.get("version", ""), x.get("arch", ""), x.get("mode", ""), x.get("category", ""), x.get("reason", "")] for x in pending),
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
        "pending": pending_details,
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
    if pending_details:
        lines += ["", "## Required variants still pending", ""]
        lines += table(
            ["Target", "Version", "Arch", "Mode", "Category", "Reason"],
            ([x.get("target", ""), x.get("version", ""), x.get("arch", ""), x.get("mode", ""), x.get("category", ""), x.get("reason", "")] for x in pending_details),
        )
    if failed_sources:
        lines += ["", "## Source candidates that did not become ready", ""]
        lines += table(
            ["Target", "Version", "Compatibility", "Outcome", "Exit"],
            ([x.get("target", ""), x.get("version", ""), x.get("compatibility", ""), x.get("acquisitionOutcome", ""), x.get("exitCode", "")] for x in failed_sources[:30]),
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
