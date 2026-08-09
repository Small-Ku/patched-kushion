#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

# Morphe Desktop intentionally exposes asymmetric long option names here:
# list-patches takes --filter-package-name (singular), while list-versions takes
# --filter-package-names (plural). Keep this executable test so a mechanical
# rename cannot silently break one of the commands.
# shellcheck disable=SC1091
source utils.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/java-home/bin"
cat > "$tmp/java-home/bin/java" <<'JAVA'
#!/usr/bin/env bash
set -euo pipefail

[ "$1" = --enable-native-access=ALL-UNNAMED ]
shift
[ "$1" = -jar ]
[[ "$2" == */morphe-desktop.jar ]]
case "$3" in
  list-patches)
    [ "$4" = --patches ]
    [[ "$5" == */patches.mpp ]]
    [ "$6" = --filter-package-name ]
    [ "$7" = com.example.app ]
    [ "$8" = --with-versions ]
    [ "$9" = --with-packages ]
    [ "$#" -eq 9 ]
    printf 'Name: Example patch\n'
    ;;
  list-versions)
    [ "$4" = --patches ]
    [[ "$5" == */patches.mpp ]]
    [ "$6" = --filter-package-names ]
    [ "$7" = com.example.app ]
    [ "$#" -eq 7 ]
    printf 'Most common compatible versions:\nAny\n'
    ;;
  *)
    echo "unexpected Morphe command: $*" >&2
    exit 2
    ;;
esac
JAVA
chmod +x "$tmp/java-home/bin/java"

export EXPECTED_CLI="$tmp/morphe-desktop.jar"
export EXPECTED_PATCHES="$tmp/patches.mpp"
export EXPECTED_PACKAGE=com.example.app

export JAVA_HOME_21_X64="$tmp/java-home"

patches_list \
  "$EXPECTED_CLI" "$EXPECTED_PATCHES" "$EXPECTED_PACKAGE" |
  grep -Fq 'Name: Example patch'

patches_list_versions \
  "$EXPECTED_CLI" "$EXPECTED_PATCHES" "$EXPECTED_PACKAGE" |
  grep -Fq 'Most common compatible versions:'

# Guard the exact interface even if the helper functions are later refactored.
grep -Fq 'list-patches --patches "$patches_jar" --filter-package-name "$pkg_name"' utils.sh
grep -Fq 'list-versions --patches "$patches_jar" --filter-package-names "$pkg_name"' utils.sh
if grep -Fq 'list-patches --patches "$patches_jar" --filter-package-names "$pkg_name"' utils.sh; then
  echo >&2 'list-patches regressed to unsupported plural filter option'
  exit 1
fi

echo 'Morphe CLI interface test passed'
