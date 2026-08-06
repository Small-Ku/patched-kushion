#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

usage() {
	cat <<'USAGE'
Usage: sync-fdroid-releases.sh <fdroid-repo-directory>

Downloads APK assets from the newest non-draft, non-prerelease GitHub releases.
The environment must provide GITHUB_REPOSITORY and GH_TOKEN. Set
FDROID_RELEASE_LIMIT to control how many releases are retained (default: 10).
USAGE
}

if [ "$#" -ne 1 ]; then
	usage >&2
	exit 2
fi

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

release_limit=${FDROID_RELEASE_LIMIT:-10}
if ! [[ "$release_limit" =~ ^[1-9][0-9]*$ ]]; then
	echo "FDROID_RELEASE_LIMIT must be a positive integer, got '$release_limit'" >&2
	exit 2
fi

for command in gh cp find mktemp sort; do
	command -v "$command" >/dev/null || {
		echo "Required command not found: $command" >&2
		exit 1
	}
done

repo_dir=$1
mkdir -p "$repo_dir"
rm -f "$repo_dir"/*.apk

mapfile -t all_release_tags < <(
	gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
		--jq '.[] | select(.draft == false and .prerelease == false) | .tag_name'
)
release_tags=("${all_release_tags[@]:0:release_limit}")

if [ "${#release_tags[@]}" -eq 0 ]; then
	echo "No published releases found for ${GITHUB_REPOSITORY}" >&2
	exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# GitHub returns newest releases first. Process oldest-to-newest so that a
# rebuilt asset with the same filename is replaced by the newest release.
for ((index = ${#release_tags[@]} - 1; index >= 0; index--)); do
	tag=${release_tags[$index]}
	tag_dir="$work_dir/$index"
	mkdir -p "$tag_dir"

	if ! gh release download "$tag" \
		--repo "$GITHUB_REPOSITORY" \
		--pattern '*.apk' \
		--dir "$tag_dir"; then
		echo "Release '$tag' has no downloadable APK assets; skipping" >&2
		continue
	fi

	for apk in "$tag_dir"/*.apk; do
		cp -f "$apk" "$repo_dir/$(basename "$apk")"
	done
done

apks=("$repo_dir"/*.apk)
if [ "${#apks[@]}" -eq 0 ]; then
	echo "No APK assets were downloaded from the selected releases" >&2
	exit 1
fi

printf 'Prepared %d APK(s) for F-Droid indexing:\n' "${#apks[@]}"
find "$repo_dir" -maxdepth 1 -type f -name '*.apk' -printf '%f\n' | sort
