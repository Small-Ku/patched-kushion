#!/usr/bin/env bash
set -euo pipefail

python_bin=$(command -v python || true)
java_bin=$(command -v java || true)
keytool_bin=$(command -v keytool || true)

[ -n "$python_bin" ] || { echo >&2 'pixi toolchain has no python'; exit 1; }
[ -n "$java_bin" ] || { echo >&2 'pixi toolchain has no java'; exit 1; }
[ -n "$keytool_bin" ] || { echo >&2 'pixi toolchain has no keytool'; exit 1; }

python_version=$(python --version 2>&1)
java_version=$(java -version 2>&1 | head -1)
java_settings=$(java -XshowSettings:properties -version 2>&1 || true)
java_vendor=$(sed -n 's/^[[:space:]]*java.vendor = //p' <<<"$java_settings" | head -1)
java_vm=$(sed -n 's/^[[:space:]]*java.vm.name = //p' <<<"$java_settings" | head -1)

if ! grep -qi 'graalvm' <<<"$java_settings $java_version $java_vm $java_vendor"; then
  echo >&2 "Locked JVM is not GraalVM: ${java_version:-unknown}"
  exit 1
fi

printf 'Locked toolchain: %s; %s; vendor=%s; vm=%s\n' \
  "$python_version" "$java_version" "${java_vendor:-unknown}" "${java_vm:-unknown}"
