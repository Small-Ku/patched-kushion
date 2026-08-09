#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

if git ls-files | grep -E '(^|/)(ks(-p12)?\.keystore|[^/]+\.(jks|p12|pfx|pkcs12|key))$'; then
	echo >&2 "Private signing material is tracked by Git"
	exit 1
fi

if git ls-files | grep -E '^(fdroid/config\.yml|fdroid-signing/)'; then
	echo >&2 "Generated F-Droid signing credentials are tracked by Git"
	exit 1
fi

if git grep -I -n -F '123456789' -- ':!tests/no-signing-secrets-test.sh'; then
	echo >&2 "Retired hard-coded signing password remains in the source tree"
	exit 1
fi
