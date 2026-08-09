#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

python3 - <<'PY'
from pathlib import Path
import re

expected = {
    ".github/workflows/pipeline.yml": "Update",
    ".github/workflows/build.yml": "Build Variant",
    ".github/workflows/fdroid.yml": "Publish F-Droid",
    ".github/workflows/fdroid-watch.yml": "Check F-Droid Sources",
    ".github/workflows/validate.yml": "Validate",
}
for filename, name in expected.items():
    first = Path(filename).read_text(encoding="utf-8").splitlines()[0]
    assert first == f"name: {name}", (filename, first)

files = [Path("README.md"), Path("CONFIG.md")]
files += [p for p in Path("docs").glob("*.md") if p.name != "writing-style.md"]
files += list(Path(".github/workflows").glob("*.yml"))
text = "\n".join(p.read_text(encoding="utf-8") for p in files)
for word in ("atomic", "reconcile", "reconciliation", "checkpoint"):
    assert not re.search(rf"\b{word}\w*\b", text, re.IGNORECASE), word

assert "fdroid_sources.py check" in Path(".github/workflows/pipeline.yml").read_text()
assert "fdroid_sources.py check" in Path(".github/workflows/fdroid-watch.yml").read_text()
PY

echo "repository wording test passed"
