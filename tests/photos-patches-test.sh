#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root/config.toml" <<'PY'
import shlex, sys, tomllib
cfg=tomllib.load(open(sys.argv[1],'rb'))['apps']['KouPhotos']['build']
assert cfg['patches-source']=='RookieEnough/De-Vanced'
assert cfg['exclusive-patches'] is True
selected=set()
tokens=shlex.split(cfg['included-patches'])
for token in tokens:
    if token != '\\': selected.add(token)
expected={
 'Override certificate pinning',
 'Enable DCIM folders backup control',
 'Fix selected account persistence',
 'Spoof features',
}
assert selected==expected,(selected,expected)
PY
# GmsCore support and Change package name remain builder-managed: APK builds
# enable them when compatible, while root modules deliberately keep upstream
# GMS/package identity.
grep -q 'microg_patch' "$root/utils.sh"
grep -q 'find_package_identity_patch' "$root/utils.sh"
echo 'Google Photos De-Vanced patch policy test passed'
