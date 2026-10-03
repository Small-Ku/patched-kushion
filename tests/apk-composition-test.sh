#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
python3 - "$root/scripts/apk_composition.py" "$tmp/fixture.apk" <<'PY'
import importlib.util, sys, zipfile
from pathlib import Path
spec=importlib.util.spec_from_file_location("apk_composition", sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
apk=Path(sys.argv[2])
with zipfile.ZipFile(apk, "w", compression=zipfile.ZIP_STORED) as archive:
    for name, data in [
        ("lib/arm64-v8a/libsample.so", b"native"),
        ("classes.dex", b"dex1"),
        ("classes2.dex", b"dex2"),
        ("assets/model.bin", b"asset"),
        ("res/drawable/icon.png", b"resource"),
        ("resources.arsc", b"table"),
        ("META-INF/CERT.RSA", b"signature"),
        ("unknown/payload.dat", b"other"),
    ]:
        archive.writestr(name, data)
report=module.inspect_apk(apk)
assert report["totalCompressedBytes"] == 6+4+4+5+8+5+9+5
assert report["categories"]["nativeLibraries"]["compressedBytes"] == 6
assert report["categories"]["dex"]["entryCount"] == 2
assert report["categories"]["assets"]["compressedBytes"] == 5
assert report["categories"]["resources"]["compressedBytes"] == 8
assert report["categories"]["resourcesArsc"]["compressedBytes"] == 5
assert report["categories"]["metaInf"]["compressedBytes"] == 9
assert report["categories"]["other"]["compressedBytes"] == 5
assert report["nativeLibrariesByAbi"] == {"arm64-v8a": 6}
assert report["containerBytes"] == apk.stat().st_size-report["totalCompressedBytes"]
print("APK compressed ZIP composition test passed")
PY
