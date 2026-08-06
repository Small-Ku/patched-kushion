#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: sync-fdroid-releases.sh <fdroid-repo-directory> [provenance-json]

Downloads, validates, and stages every APK configured in fdroid/sources.toml.
The GitHub CLI must be authenticated (or GH_TOKEN set), and GITHUB_REPOSITORY
is required for the @self source. External private sources may additionally use
the token environment variable named in their source entry.
USAGE
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	usage >&2
	exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir=$1
provenance=${2:-"$(dirname "$repo_dir")/provenance.json"}

exec python3 "$root/scripts/fdroid_sources.py" sync \
	--config "$root/fdroid/sources.toml" \
	--repo-dir "$repo_dir" \
	--provenance "$provenance"
