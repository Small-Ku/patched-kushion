#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 "$root/scripts/fdroid_sources.py" add \
	--config "$root/config.toml" "$@"
