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
test -s "$tmp/metadata/de.kwoo.shion.instagram.yml"
test -s "$tmp/metadata/de.kwoo.shion.messenger.yml"
test ! -e "$tmp/metadata/de.kwoo.shion.x.yml"
test ! -e "$tmp/metadata/de.kwoo.shion.threads.yml"
test ! -e "$tmp/metadata/de.kwoo.shion.facebook.yml"
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
toml_prep config.toml
load_app_catalog config.toml
validate_build_apps
test "$(package_identity_for_app KouTube)" = de.kwoo.shion.youtube
test "$(package_identity_for_app KouMusik)" = de.kwoo.shion.music
test "$(package_identity_for_app KouPhotos)" = de.kwoo.shion.photos
test "$(package_identity_for_app KouInstagram)" = de.kwoo.shion.instagram
test "$(package_identity_for_app KouMessenger)" = de.kwoo.shion.messenger
test "$(jq -r '.apps.KouX.build."build-mode"' <<<"$__APP_CATALOG__")" = module
! jq -e '.apps.KouThreads' >/dev/null <<<"$__APP_CATALOG__"
! jq -e '.apps.KouFacebook' >/dev/null <<<"$__APP_CATALOG__"
if package_identity_for_app sing-box >/dev/null 2>&1; then
  echo >&2 "external release app unexpectedly owns a local package-signing identity"
  exit 1
fi

current_patch_list=$'Name: GmsCore support\nName: Clone app\nName: Other patch'
legacy_patch_list=$'Name: GmsCore support\nName: Change package name\nName: Other patch'
test "$(find_package_identity_patch "$current_patch_list")" = 'Clone app'
test "$(find_package_identity_patch "$legacy_patch_list")" = 'Change package name'
if find_package_identity_patch $'Name: GmsCore support\nName: Other patch' >/dev/null 2>&1; then
  echo >&2 "package identity patch unexpectedly detected"
  exit 1
fi

declare -a managed_patch_args=(' -e "Clone app" -e "Other patch" -d "GmsCore support" ')
remove_managed_patch_selection managed_patch_args 'Clone app'
remove_managed_patch_selection managed_patch_args 'GmsCore support'
[[ ${managed_patch_args[*]} != *'Clone app'* ]]
[[ ${managed_patch_args[*]} != *'GmsCore support'* ]]
[[ ${managed_patch_args[*]} == *'Other patch'* ]]

declare -a patch_args=()
configure_nonroot_app_identity apk 'Clone app' de.kwoo.shion.photos com.google.android.apps.photos '' patch_args
test "${patch_args[*]}" = '-e "Clone app" -OpackageName=de.kwoo.shion.photos'

declare -a module_args=()
configure_nonroot_app_identity module 'Clone app' de.kwoo.shion.photos com.google.android.apps.photos '' module_args
test "${module_args[*]}" = '-d "Clone app"'

declare -a missing_patch_args=()

preserve_args=()
configure_nonroot_app_identity apk '' com.twitter.android com.twitter.android '' preserve_args
[ "${#preserve_args[@]}" -eq 0 ] || { echo "same-package app should not require a clone patch" >&2; exit 1; }

if configure_nonroot_app_identity apk '' de.kwoo.shion.photos com.google.android.apps.photos '' missing_patch_args 2>/dev/null; then
  echo >&2 "stable identity unexpectedly accepted without a compatible package-name patch"
  exit 1
fi

declare -a duplicate_args=()
if configure_nonroot_app_identity apk 'Clone app' de.kwoo.shion.photos com.google.android.apps.photos '-OpackageName=manual.example' duplicate_args 2>/dev/null; then
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

# Linux CI does not ship the repo's Android/ARM aapt2 prebuilt. Verify that
# identity inspection discovers the newest aapt2 from Android SDK build-tools.
mkdir -p "$tmp/sdk/build-tools/35.0.0" "$tmp/sdk/build-tools/37.0.0" "$tmp/empty-bin"
for version in 35.0.0 37.0.0; do
  cat > "$tmp/sdk/build-tools/$version/aapt2" <<'AAPT'
#!/usr/bin/env bash
printf '%s\n' "$0"
AAPT
  chmod +x "$tmp/sdk/build-tools/$version/aapt2"
done
unset AAPT2
resolved=$(BIN_DIR="$tmp/empty-bin" ANDROID_HOME="$tmp/sdk" ANDROID_SDK_ROOT= HOME="$tmp/home" resolve_aapt2)
test "$resolved" = "$tmp/sdk/build-tools/37.0.0/aapt2"

echo "stable app identity test passed"
