#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixtures=tests/fixtures/photos-account-backup
src=kushion-patches/extensions/photos-account-backup/src/main/java/de/kwoo/shion/extension/photos/AccountScopedFolders.java
javac -d "$tmp" "$fixtures"/android/content/*.java "$fixtures"/android/util/*.java "$src" "$fixtures"/PhotosAccountBackupBridgeTest.java
java -cp "$tmp" PhotosAccountBackupBridgeTest
