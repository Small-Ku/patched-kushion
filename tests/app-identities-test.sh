#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

python3 scripts/app_catalog.py validate >/dev/null

python3 - <<'PY'
from pathlib import Path
import subprocess

readme = Path("README.md").read_text(encoding="utf-8")
start = "<!-- BEGIN APP CATALOG -->\n"
end = "\n<!-- END APP CATALOG -->"
actual = readme.split(start, 1)[1].split(end, 1)[0]
expected = subprocess.check_output(
    ["python3", "scripts/app_catalog.py", "markdown"], text=True
).rstrip("\n")
assert actual == expected
PY

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 scripts/app_catalog.py write-metadata \
  --metadata-dir "$tmp/metadata" \
  --repository example/patched-kushion

test -s "$tmp/metadata/de.kwoo.shion.youtube.yml"
test -s "$tmp/metadata/de.kwoo.shion.music.yml"
test -s "$tmp/metadata/de.kwoo.shion.photos.yml"
grep -Fq 'Current patch bundle: De-Vanced (RookieEnough/De-Vanced)' \
  "$tmp/metadata/de.kwoo.shion.photos.yml"
grep -Fq 'Stable package identity: de.kwoo.shion.photos' \
  "$tmp/metadata/de.kwoo.shion.photos.yml"
grep -Fq 'not an official Morphe release and not affiliated with Morphe' \
  "$tmp/metadata/de.kwoo.shion.youtube.yml"
grep -Fq 'Morphe NOTICE required by its patch license is included in the APK' \
  "$tmp/metadata/de.kwoo.shion.music.yml"
if grep -Fq 'Morphe NOTICE' "$tmp/metadata/de.kwoo.shion.photos.yml"; then
  echo >&2 "De-Vanced metadata unexpectedly inherited the Morphe notice"
  exit 1
fi


# Exercise the same shell lookup and package-option path used by build.sh.
# shellcheck disable=SC1091
source utils.sh
TOML=bin/toml/tq-x86_64
load_app_identities package-identities.toml
toml_prep config.toml
validate_app_identity_targets config.toml
cat > "$tmp/partial-config.json" <<'JSON'
{
  "GooglePhotos-DeVanced": {
    "app-name": "KouPhotos",
    "build-mode": "both"
  }
}
JSON
toml_prep "$tmp/partial-config.json"
validate_app_identity_targets "$tmp/partial-config.json"
toml_prep config.toml
test "$(package_identity_for_target YouTube-Morphe)" = de.kwoo.shion.youtube
test "$(package_identity_for_target Music-Morphe)" = de.kwoo.shion.music
test "$(package_identity_for_target GooglePhotos-DeVanced)" = de.kwoo.shion.photos
if package_identity_for_target GooglePhotos >/dev/null 2>&1; then
  echo >&2 "alternative Google Photos target unexpectedly owns the stable identity"
  exit 1
fi

declare -a managed_patch_args=(' -e "Change package name" -e "Other patch" -d "GmsCore support" ')
remove_managed_patch_selection managed_patch_args 'Change package name'
remove_managed_patch_selection managed_patch_args 'GmsCore support'
[[ ${managed_patch_args[*]} != *'Change package name'* ]]
[[ ${managed_patch_args[*]} != *'GmsCore support'* ]]
[[ ${managed_patch_args[*]} == *'Other patch'* ]]

declare -a patch_args=()
configure_nonroot_app_identity apk 'Change package name' de.kwoo.shion.photos '' patch_args
test "${patch_args[*]}" = '-e "Change package name" -OpackageName=de.kwoo.shion.photos'

declare -a module_args=()
configure_nonroot_app_identity module 'Change package name' de.kwoo.shion.photos '' module_args
test "${module_args[*]}" = '-d "Change package name"'

declare -a missing_patch_args=()
if configure_nonroot_app_identity apk '' de.kwoo.shion.photos '' missing_patch_args 2>/dev/null; then
  echo >&2 "stable identity unexpectedly accepted without a compatible package-name patch"
  exit 1
fi

declare -a duplicate_args=()
if configure_nonroot_app_identity apk 'Change package name' de.kwoo.shion.photos '-OpackageName=manual.example' duplicate_args 2>/dev/null; then
  echo >&2 "manual packageName override unexpectedly accepted"
  exit 1
fi

cat > "$tmp/aapt2" <<'AAPT'
#!/usr/bin/env bash
printf "package: name='%s' versionCode='1' versionName='1.0'\n" "$FAKE_PACKAGE"
AAPT
chmod +x "$tmp/aapt2"
printf 'not a real apk\n' > "$tmp/app.apk"
AAPT2="$tmp/aapt2"
FAKE_PACKAGE=de.kwoo.shion.photos verify_apk_package_identity \
  "$tmp/app.apk" de.kwoo.shion.photos
if FAKE_PACKAGE=wrong.package verify_apk_package_identity \
  "$tmp/app.apk" de.kwoo.shion.photos 2>/dev/null; then
  echo >&2 "mismatched final APK package unexpectedly accepted"
  exit 1
fi

echo "stable app identity test passed"
