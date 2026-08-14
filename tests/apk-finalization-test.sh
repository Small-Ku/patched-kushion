#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

# shellcheck disable=SC1091
source utils.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp"
printf 'payload\n' > "$tmp/input.apk"

cat > "$tmp/zipalign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'zipalign' >> "$FINALIZE_LOG"
printf ' %q' "$@" >> "$FINALIZE_LOG"
printf '\n' >> "$FINALIZE_LOG"
if [ "$1" = -c ]; then
  exit 0
fi
cp -f "${@: -2:1}" "${@: -1}"
SH
chmod +x "$tmp/zipalign"
ZIPALIGN="$tmp/zipalign"
export ZIPALIGN
FINALIZE_LOG="$tmp/finalize.log"
export FINALIZE_LOG

sign_apk() {
  printf 'sign %s %s\n' "$1" "$2" >> "$FINALIZE_LOG"
  cp -f "$1" "$2"
}
verify_apk_signature() {
  printf 'verify %s\n' "$1" >> "$FINALIZE_LOG"
}

finalize_apk "$tmp/input.apk" "$tmp/output.apk"
cmp "$tmp/input.apk" "$tmp/output.apk"

mapfile -t log < "$FINALIZE_LOG"
[ "${#log[@]}" -eq 4 ]
[[ "${log[0]}" == zipalign\ -P\ 16\ -f\ 4\ * ]]
[[ "${log[1]}" == sign\ * ]]
[[ "${log[2]}" == verify\ * ]]
[[ "${log[3]}" == zipalign\ -c\ -P\ 16\ 4\ * ]]

mkdir -p "$tmp/sdk/build-tools/35.0.0" "$tmp/sdk/build-tools/36.0.0"
printf '#!/bin/sh\n' > "$tmp/sdk/build-tools/35.0.0/zipalign"
printf '#!/bin/sh\n' > "$tmp/sdk/build-tools/36.0.0/zipalign"
chmod +x "$tmp/sdk/build-tools/35.0.0/zipalign" "$tmp/sdk/build-tools/36.0.0/zipalign"
unset ZIPALIGN
resolved=$(PATH=/usr/bin:/bin ANDROID_HOME="$tmp/sdk" ANDROID_SDK_ROOT= HOME="$tmp/home" resolve_zipalign)
[ "$resolved" = "$tmp/sdk/build-tools/36.0.0/zipalign" ]

echo "apk finalization test passed"
