#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$repo" "$tmp/universal.apk" <<'PY'
import importlib.util
import sys
import zipfile
from pathlib import Path

repo = Path(sys.argv[1])
apk = Path(sys.argv[2])
with zipfile.ZipFile(apk, "w") as zf:
    for abi in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64"):
        zf.writestr(f"lib/{abi}/libfixture.so", b"fixture")

spec = importlib.util.spec_from_file_location("fdroid_sources", repo / "scripts/fdroid_sources.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
actual = module.native_codes_from_apk(apk)
expected = ("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
assert actual == expected, (actual, expected)
PY

echo "fdroid APK native-code scan test passed"
