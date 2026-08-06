#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo"

cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = api ]; then
	printf '%s\n' 3 2 1
	exit 0
fi

if [ "$1" = release ] && [ "$2" = download ]; then
	tag=$3
	shift 3
	dir=
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--dir)
				dir=$2
				shift 2
				;;
			--repo|--pattern)
				shift 2
				;;
			*)
				echo "unexpected fake gh argument: $1" >&2
				exit 2
				;;
		esac
	done
	mkdir -p "$dir"
	printf 'release-%s\n' "$tag" > "$dir/app-v${tag}.apk"
	printf 'release-%s\n' "$tag" > "$dir/rebuilt.apk"
	exit 0
fi

echo "unexpected fake gh invocation: $*" >&2
exit 2
FAKE_GH
chmod +x "$tmp/bin/gh"

PATH="$tmp/bin:$PATH" \
GITHUB_REPOSITORY=example/patched-kushion \
GH_TOKEN=test-token \
FDROID_RELEASE_LIMIT=2 \
	"$root/scripts/sync-fdroid-releases.sh" "$tmp/repo" >/dev/null

test -f "$tmp/repo/app-v2.apk"
test -f "$tmp/repo/app-v3.apk"
test ! -e "$tmp/repo/app-v1.apk"
grep -qx 'release-3' "$tmp/repo/rebuilt.apk"

echo "fdroid release sync test passed"
