#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=tests/fixtures/photos-account-backup
src=kushion-patches/extensions/photos-account-backup/src/main/java/de/kwoo/shion/extension/photos/BackupAccountFollower.java
folders_src=kushion-patches/extensions/photos-account-backup/src/main/java/de/kwoo/shion/extension/photos/AccountScopedFolders.java
javac -d "$tmp" \
  "$base"/android/content/*.java "$base"/android/util/*.java "$base"/android/widget/*.java \
  "$base"/NativeBackupFakes.java "$base"/BackupAccountFollowerTest.java "$src" "$folders_src"
java -cp "$tmp" BackupAccountFollowerTest
