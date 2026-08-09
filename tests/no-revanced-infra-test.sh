#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

files=(build.sh build-termux.sh utils.sh config.toml CONFIG.md scripts/app_catalog.py .github/ISSUE_TEMPLATE/bug_report.md)
for forbidden in \
  'ReVanced/revanced-patches' \
  'revanced/revanced-patches' \
  'ReVanced/revanced-cli' \
  'MorpheApp/morphe-cli' \
  'revanced-magisk-module' \
  'rvmm-config-gen' \
  'api.github.com/repos/ReVanced/' \
  'remove-rv-integrations-checks' \
  'REMOVE_RV_INTEGRATIONS_CHECKS' \
  'rv-brand' \
  'build_rv'
do
  if grep -FIn -- "$forbidden" "${files[@]}"; then
    echo >&2 "legacy ReVanced infrastructure path remains: $forbidden"
    exit 1
  fi
done

# MicroG RE deliberately keeps this package identity for compatibility. It is
# not an external ReVanced service dependency and must not be renamed here.
grep -Fq 'app.revanced.android.gms' fdroid/sources.toml

test ! -e bin/paccer.jar
test ! -e bin/dexlib2.jar

grep -Fq 'list-versions --patches "$patches_jar" --filter-package-names "$pkg_name"' utils.sh
grep -Fq 'list-patches --patches "$patches_jar" --filter-package-name "$pkg_name"' utils.sh
grep -Fq 'endswith(".mpp")' utils.sh

echo "no ReVanced infrastructure dependency test passed"
