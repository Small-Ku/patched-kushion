#!/usr/bin/env python3
"""Fingerprint the same-source Kushion Patches bundle and verify downloaded handoffs."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SOURCE = Path("kushion-patches")
BUNDLE = "kushion-patches.mpp"


def source_digest(root: Path = SOURCE) -> str:
    digest = hashlib.sha256()
    for file in sorted(root.rglob("*")):
        if not file.is_file() or any(part in {"build", ".gradle", ".kotlin"} for part in file.relative_to(root).parts):
            continue
        digest.update(file.relative_to(root).as_posix().encode() + b"\0")
        digest.update(file.read_bytes() + b"\0")
    digest.update(Path("LICENSE").read_bytes())
    return digest.hexdigest()


def bundle_identity(bundle: Path) -> dict:
    return {"kind": "in-repo", "source": "kushion-patches", "sourceSha256": source_digest(),
            "sha256": hashlib.sha256(bundle.read_bytes()).hexdigest(), "name": BUNDLE}


def verify(root: Path, expected: dict | None = None) -> dict:
    metadata = json.loads((root / "kushion-patches.json").read_text())
    actual = bundle_identity(root / BUNDLE)
    if metadata != actual or (expected is not None and expected != actual):
        raise SystemExit("Kushion Patches bundle handoff does not match source/bytes/planned identity")
    return actual


def planned_identity(target: str, config: dict, manifest: Path | None) -> dict | None:
    if target != "KouPhotos":
        return None
    if config.get("identity-patches-source") != "in-repo":
        raise SystemExit("KouPhotos requires identity-patches-source = in-repo")
    if manifest is None:
        # Read-only planning/tests can fingerprint source, but production planning supplies built bytes.
        return {"kind": "in-repo", "source": "kushion-patches", "sourceSha256": source_digest()}
    return verify(manifest.parent)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["write", "verify"])
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--expected", type=Path)
    args = parser.parse_args()
    if args.command == "write":
        identity = bundle_identity(args.root / BUNDLE)
        (args.root / "kushion-patches.json").write_text(json.dumps(identity, indent=2) + "\n")
    else:
        expected = json.loads(args.expected.read_text()) if args.expected else None
        identity = verify(args.root, expected)
    print(json.dumps(identity, sort_keys=True))


if __name__ == "__main__":
    main()
