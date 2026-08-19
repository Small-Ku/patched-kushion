#!/usr/bin/env bash
set -euo pipefail

BCPROV_VERSION=${BCPROV_VERSION:-1.84}
BCPROV_SHA256=${BCPROV_SHA256:-64d6c5a6121fcd927152dd182cbed39afe0fda641a970d9bcc0c9cb1858b2731}
BCPROV_URL=${BCPROV_URL:-https://repo.maven.apache.org/maven2/org/bouncycastle/bcprov-jdk18on/${BCPROV_VERSION}/bcprov-jdk18on-${BCPROV_VERSION}.jar}

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo >&2 "sha256sum or shasum is required"
    return 1
  fi
}

verify_bcprov() {
  local candidate=$1 actual
  [ -f "$candidate" ] || return 1
  actual=$(sha256_file "$candidate") || return 1
  [ "$actual" = "$BCPROV_SHA256" ]
}

download() {
  local url=$1 output=$2
  if command -v curl >/dev/null; then
    curl --fail --location --retry 3 --silent --show-error "$url" --output "$output"
  elif command -v wget >/dev/null; then
    wget -qO "$output" "$url"
  else
    echo >&2 "curl or wget is required to download Bouncy Castle"
    return 1
  fi
}

if [ -n "${BCPROV_JAR:-}" ]; then
  if ! verify_bcprov "$BCPROV_JAR"; then
    actual=missing
    [ ! -f "$BCPROV_JAR" ] || actual=$(sha256_file "$BCPROV_JAR")
    echo >&2 "BCPROV_JAR is not the pinned Bouncy Castle ${BCPROV_VERSION} provider: $BCPROV_JAR (SHA-256: $actual)"
    exit 1
  fi
  printf '%s\n' "$BCPROV_JAR"
  exit 0
fi

for candidate in /usr/share/java/bcprov.jar "/usr/share/java/bcprov-${BCPROV_VERSION}.jar"; do
  if verify_bcprov "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

cache_dir=${XDG_CACHE_HOME:-${HOME:-.}/.cache}/patched-kushion
candidate="$cache_dir/bcprov-jdk18on-${BCPROV_VERSION}.jar"
mkdir -p "$cache_dir"
if ! verify_bcprov "$candidate"; then
  tmp="${candidate}.tmp.$$"
  trap 'rm -f "$tmp"' EXIT
  echo >&2 "Downloading verified Bouncy Castle ${BCPROV_VERSION} provider..."
  download "$BCPROV_URL" "$tmp"
  actual=$(sha256_file "$tmp")
  if [ "$actual" != "$BCPROV_SHA256" ]; then
    echo >&2 "Bouncy Castle SHA-256 mismatch: $actual"
    exit 1
  fi
  mv -f "$tmp" "$candidate"
  trap - EXIT
fi
printf '%s\n' "$candidate"
