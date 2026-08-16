#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

if git ls-files | grep -E '(^|/)(ks(-p12)?\.keystore|[^/]+\.(jks|p12|pfx|pkcs12|key))$'; then
	echo >&2 "Private signing material is tracked by Git"
	exit 1
fi

if git ls-files | grep -E '^(fdroid/config\.yml|signing/fdroid/)'; then
	echo >&2 "Generated F-Droid signing credentials are tracked by Git"
	exit 1
fi

if git grep -I -n -F '123456789' -- ':!tests/no-signing-secrets-test.sh'; then
	echo >&2 "Retired hard-coded signing password remains in the source tree"
	exit 1
fi

# Network acquisition and offline stock materialization must never receive the
# package signing identity. Morphe may sign its patch-stage intermediate, while
# final release signing remains in Package.
if grep -q 'secrets\.APK_' .github/workflows/build.yml; then
	echo >&2 "Source workflow unexpectedly receives APK signing secrets"
	exit 1
fi
python3 - <<'PY'
from pathlib import Path
text=Path('.github/workflows/build-arch.yml').read_text()
stock=text.split('\n  patch:\n',1)[0]
if 'secrets.APK_' in stock or 'APK_KEYSTORE_PASSWORD' in stock:
    raise SystemExit('Stock job unexpectedly receives APK signing secrets')
PY
