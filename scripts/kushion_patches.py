#!/usr/bin/env python3
"""Fingerprint the same-source Kushion Patches bundle and verify downloaded handoffs."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SOURCE = Path("kushion-patches")
BUNDLE = "kushion-patches.mpp"
KNIT_TARGETS = {
    "KouTube": ("de.kwoo.shion.youtube", "KnitTube"),
    "KouMusik": ("de.kwoo.shion.music", "KnitMusic"),
    "KouPhotos": ("de.kwoo.shion.photos", "KnitPhotos"),
    "KouInstagram": ("de.kwoo.shion.instagram", "Knitstagram"),
    "KouMessenger": ("de.kwoo.shion.messenger", "KnitMessenger"),
}


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


def planned_bundle(target: str, mode: str, package_name: str, manifest: Path | None) -> dict | None:
    if mode != "apk" or target not in KNIT_TARGETS:
        return None
    expected_package, _ = KNIT_TARGETS[target]
    if package_name != expected_package:
        raise SystemExit(f"{target} Knit branding requires stable package {expected_package}")
    if manifest is None:
        # Read-only planning/tests can fingerprint source, but production planning supplies built bytes.
        return {"kind": "in-repo", "source": "kushion-patches", "sourceSha256": source_digest()}
    return verify(manifest.parent)


def supports_target(target: str) -> bool:
    return target in KNIT_TARGETS


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["write", "verify", "supports"])
    parser.add_argument("--target")
    parser.add_argument("--root", type=Path)
    parser.add_argument("--expected", type=Path)
    args = parser.parse_args()
    if args.command == "supports":
        if not args.target:
            raise SystemExit("supports requires --target")
        print("true" if supports_target(args.target) else "false")
        return
    if args.root is None:
        raise SystemExit(f"{args.command} requires --root")
    if args.command == "write":
        identity = bundle_identity(args.root / BUNDLE)
        (args.root / "kushion-patches.json").write_text(json.dumps(identity, indent=2) + "\n")
    else:
        expected = json.loads(args.expected.read_text()) if args.expected else None
        identity = verify(args.root, expected)
    print(json.dumps(identity, sort_keys=True))


if __name__ == "__main__":
    main()
