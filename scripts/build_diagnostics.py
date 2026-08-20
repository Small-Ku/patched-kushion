#!/usr/bin/env python3
"""Classify captured build-stage failures into small structured diagnostics.

Verbose stage logs stay in short-lived artifacts.  This helper extracts the
stable facts that the Actions summary needs so publication health can explain
why a candidate failed without requiring manual log inspection.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import OrderedDict
from pathlib import Path
from typing import Any

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def clean_lines(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
    return [ANSI_RE.sub("", line).strip() for line in text.splitlines() if line.strip()]


def provider_from_url(url: str) -> str:
    lowered = url.lower()
    for name, needles in (
        ("apkmirror", ("apkmirror.com",)),
        ("apkpure", ("apkpure.com", "apkeep")),
        ("uptodown", ("uptodown.com",)),
        ("aptoide", ("aptoide.com",)),
        ("archive", ("archive.org",)),
    ):
        if any(needle in lowered for needle in needles):
            return name
    return "unknown"


def source_diagnostics(lines: list[str], exit_code: str) -> dict[str, Any]:
    attempts: "OrderedDict[tuple[str, str], dict[str, Any]]" = OrderedDict()
    events: list[dict[str, Any]] = []
    current_provider = ""
    current_arch = ""
    root_reason = ""
    pending_http_status = ""

    def attempt(provider: str, arch: str = "") -> dict[str, Any]:
        provider = provider or "unknown"
        key = (provider, arch or "")
        if key not in attempts:
            attempts[key] = {
                "provider": provider,
                "arch": arch or "",
                "status": "unavailable",
                "category": "unknown",
                "reason": "",
            }
        return attempts[key]

    def record(
        provider: str,
        arch: str,
        category: str,
        reason: str,
        *,
        status: str = "unavailable",
        details: dict[str, Any] | None = None,
        priority: int = 10,
    ) -> None:
        row = attempt(provider, arch)
        if priority >= int(row.get("_priority", -1)):
            row.update({"status": status, "category": category, "reason": reason, "_priority": priority})
            if details:
                row.update(details)
        event = {"provider": provider or "unknown", "arch": arch or "", "category": category, "reason": reason}
        if details:
            event.update(details)
        if event not in events:
            events.append(event)

    for line in lines:
        m = re.search(r"curl: \(22\) The requested URL returned error: (\d{3})", line)
        if m:
            pending_http_status = m.group(1)
            continue

        m = re.search(r"Traversing '([^']+)' source DAG node '([^']+)'", line)
        if m:
            current_arch, current_provider = m.group(1), m.group(2)
            attempt(current_provider, current_arch)
            continue

        m = re.search(r"Request failed:\s+(\S+)", line)
        if m:
            url = m.group(1)
            provider = provider_from_url(url)
            details: dict[str, Any] = {"url": url}
            if pending_http_status:
                details["httpStatus"] = int(pending_http_status)
            record(provider, current_arch if provider == current_provider else "", "metadata-request-failed", f"request failed: {url}" + (f" (HTTP {pending_http_status})" if pending_http_status else ""), details=details, priority=20)
            pending_http_status = ""
            continue

        m = re.search(r"Could not inspect '([^']+)' for '([^']+)' DAG acquisition", line)
        if m:
            record(m.group(1), m.group(2), "metadata-unavailable", "provider metadata could not be inspected", priority=25)
            continue

        m = re.search(r"Could not inspect '([^']+)' for shared stock", line)
        if m:
            record(m.group(1), "", "metadata-unavailable", "provider metadata could not be inspected for shared stock", priority=25)
            continue

        m = re.search(r"Skipping repeated failed '([^']+)' metadata request", line)
        if m:
            record(m.group(1), current_arch, "metadata-unavailable", "provider metadata request already failed during this acquisition", priority=22)
            continue

        m = re.search(r"Aptoide exact-version node rejected: requested '([^']+)', advertised '([^']+)'", line)
        if m:
            record(
                "aptoide",
                current_arch,
                "version-mismatch",
                f"requested {m.group(1)}, advertised {m.group(2)}",
                status="rejected",
                details={"requestedVersion": m.group(1), "advertisedVersion": m.group(2)},
                priority=60,
            )
            continue

        m = re.search(r"stock bundle error: bundle can derive (.+), not ([A-Za-z0-9_.-]+)$", line)
        if m:
            actual = m.group(1).strip()
            requested = m.group(2).strip()
            record(
                current_provider,
                requested or current_arch,
                "wrong-abi",
                f"payload can derive {actual}, not {requested}",
                status="rejected",
                details={"requestedArch": requested, "actualDerivable": actual},
                priority=90,
            )
            continue

        m = re.search(r"DAG node '([^']+)' standalone APK cannot derive a distinct '([^']+)' artifact", line)
        if m:
            record(m.group(1), m.group(2), "wrong-abi", f"standalone APK cannot derive {m.group(2)}", status="rejected", priority=85)
            continue

        if "signature mismatch" in line.lower():
            provider = current_provider or "unknown"
            m = re.search(r"\(([^/()]+)/[^()]+\)", line)
            if m:
                provider = m.group(1)
            record(provider, current_arch, "signer-mismatch", line.split("[-]", 1)[-1].strip(), status="rejected", priority=100)
            continue

        m = re.search(r"DAG payload rejection: provider='([^']+)' version='([^']+)' arch='([^']+)' category='([^']+)' payloadSha256='([^']*)' reason='([^']*)'", line)
        if m:
            record(
                m.group(1), m.group(3), m.group(4), m.group(6) or m.group(4), status="rejected",
                details={"version": m.group(2), "payloadSha256": m.group(5)}, priority=95,
            )
            continue

        m = re.search(r"DAG payload node '([^']+)' failed: version='([^']+)' arch='([^']+)'", line)
        if m:
            record(m.group(1), m.group(3), "payload-failed", f"payload acquisition failed for {m.group(2)} / {m.group(3)}", priority=30)
            continue

        m = re.search(r"No source DAG path produced a complete acquisition plan for '([^']+)'", line)
        if m:
            root_reason = f"no source DAG path produced a complete acquisition plan for {m.group(1)}"
            continue

    provider_rows: list[dict[str, Any]] = []
    for row in attempts.values():
        row.pop("_priority", None)
        provider_rows.append(row)

    # Prefer a security or payload-identity rejection over generic metadata
    # outages when a concise top-level reason is needed.
    rank = {
        "signer-mismatch": 100,
        "wrong-abi": 90,
        "version-mismatch": 70,
        "payload-failed": 50,
        "metadata-unavailable": 30,
        "metadata-request-failed": 20,
        "unknown": 0,
    }
    best = max(provider_rows, key=lambda row: rank.get(str(row.get("category")), 10), default=None)
    if best and best.get("reason"):
        reason = f"{best.get('provider', 'source')}: {best['reason']}"
        category = str(best.get("category") or "source-unavailable")
    else:
        reason = root_reason or (f"source acquisition exited {exit_code}" if exit_code else "source acquisition failed")
        category = "source-unavailable"

    return {
        "schemaVersion": 1,
        "stage": "source",
        "category": category,
        "failureClass": "security" if category == "signer-mismatch" else "source",
        "reason": reason,
        "rootReason": root_reason,
        "providerAttempts": provider_rows,
        "events": events[-32:],
    }


PATCH_PATTERNS: list[tuple[int, str, str, re.Pattern[str]]] = [
    (120, "resource-exhausted", "infrastructure", re.compile(r"OutOfMemoryError|No space left on device|Killed process", re.I)),
    (115, "network-failed", "infrastructure", re.compile(r"ETIMEDOUT|ENETUNREACH|Could not resolve host|Connection timed out|java\.net\.", re.I)),
    (110, "signing-failed", "security", re.compile(r"sign(?:er|ing|ature).*(?:mismatch|failed|invalid)", re.I)),
    (105, "patch-incompatible", "compatibility", re.compile(r"fingerprint.*(?:not found|failed|missing|incompatible)|(?:not found|failed|missing).*fingerprint", re.I)),
    (100, "patch-incompatible", "compatibility", re.compile(r"no compatible patches|unsupported (?:app )?version|not compatible|incompatible with", re.I)),
    (95, "patch-incompatible", "compatibility", re.compile(r"(?:failed to apply|patch(?:ing)? .* failed|patch .* could not be applied)", re.I)),
    (90, "package-identity-failed", "configuration", re.compile(r"package identity|package-name patch|Clone app", re.I)),
    (85, "stock-preparation-failed", "input", re.compile(r"Could not prepare stock APK", re.I)),
    (80, "launcher-branding-failed", "tooling", re.compile(r"launcher branding failed|launcher-brand .* error", re.I)),
    (75, "notice-embedding-failed", "configuration", re.compile(r"patch notice could not be embedded", re.I)),
    (70, "apk-finalization-failed", "tooling", re.compile(r"APK finalization failed", re.I)),
    (65, "apkeditor-failed", "tooling", re.compile(r"APKEditor .*error", re.I)),
    (60, "patch-tool-failed", "tooling", re.compile(r"\b(?:Exception|ERROR|Error:)\b", re.I)),
    (40, "patcher-failed", "compatibility", re.compile(r"Building '.*' failed!", re.I)),
    (10, "patch-no-output", "unknown", re.compile(r"Patch preparation produced no reusable artifact", re.I)),
]


def patch_diagnostics(lines: list[str], exit_code: str) -> dict[str, Any]:
    matches: list[tuple[int, str, str, str]] = []
    for line in lines:
        for priority, category, failure_class, pattern in PATCH_PATTERNS:
            if pattern.search(line):
                matches.append((priority, category, failure_class, line))
                break

    if matches:
        # Highest specificity wins; for equal specificity use the latest line.
        best_priority = max(row[0] for row in matches)
        best = [row for row in matches if row[0] == best_priority][-1]
        _, category, failure_class, evidence = best
        reason = evidence
        # Strip our shell log prefix without changing third-party tool messages.
        if "[-]" in reason:
            reason = reason.split("[-]", 1)[1].strip()
    else:
        category = "patch-failed"
        failure_class = "unknown"
        reason = f"patch stage exited {exit_code}" if exit_code else "patch stage failed"

    evidence_rows: list[str] = []
    for _, _, _, line in sorted(matches, key=lambda row: (-row[0], lines.index(row[3]) if row[3] in lines else 0)):
        if line not in evidence_rows:
            evidence_rows.append(line)
        if len(evidence_rows) >= 5:
            break

    return {
        "schemaVersion": 1,
        "stage": "patch",
        "category": category,
        "failureClass": failure_class,
        "reason": reason,
        "evidence": evidence_rows,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=("source", "patch"))
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--exit-code", default="")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    lines = clean_lines(args.log)
    result = source_diagnostics(lines, args.exit_code) if args.stage == "source" else patch_diagnostics(lines, args.exit_code)
    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(payload, encoding="utf-8")
    print(payload, end="")


if __name__ == "__main__":
    main()
