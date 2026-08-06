#!/usr/bin/env bash

set -euo pipefail

umask 077

OUTPUT_DIR="signing"
FORCE=false
KEY_ALIAS="patched-kushion"
SIGNER_NAME="patched-kushion"
DNAME="CN=patched-kushion, OU=Package Signing, O=patched-kushion"
VALIDITY_DAYS=10000
BCPROV_VERSION="1.80"
BCPROV_SHA256="e8ad209f8c58d291a37ca9750e9e9fac60596956c983e49dd8282381dd8b3249"
BCPROV_URL="https://repo.maven.apache.org/maven2/org/bouncycastle/bcprov-jdk18on/${BCPROV_VERSION}/bcprov-jdk18on-${BCPROV_VERSION}.jar"

usage() {
	cat <<'USAGE'
Generate a new APK package-signing identity.

Usage:
  scripts/generate-package-identity.sh [options]

Options:
  --output-dir DIR    Output directory (default: signing)
  --alias NAME        Keystore alias (default: patched-kushion)
  --signer NAME       APK signer display name (default: patched-kushion)
  --dname NAME        X.509 distinguished name
  --force             Replace an existing local identity
  -h, --help          Show this help

Environment:
  BCPROV_JAR          Existing Bouncy Castle provider JAR to use
  PACKAGE_KEY_PASSWORD
                      Explicit password; a random 64-character password is
                      generated when unset
USAGE
}

while (($#)); do
	case "$1" in
	--output-dir)
		OUTPUT_DIR=${2:?missing value for --output-dir}
		shift 2
		;;
	--alias)
		KEY_ALIAS=${2:?missing value for --alias}
		shift 2
		;;
	--signer)
		SIGNER_NAME=${2:?missing value for --signer}
		shift 2
		;;
	--dname)
		DNAME=${2:?missing value for --dname}
		shift 2
		;;
	--force)
		FORCE=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo >&2 "Unknown option: $1"
		usage >&2
		exit 2
		;;
	esac
done

command -v keytool >/dev/null || {
	echo >&2 "keytool is required. Install a JDK (Java 21 is recommended)."
	exit 1
}

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

find_bcprov() {
	local candidate cache_dir actual
	for candidate in "${BCPROV_JAR-}" /usr/share/java/bcprov.jar /usr/share/java/bcprov-${BCPROV_VERSION}.jar; do
		if [ -n "$candidate" ] && [ -f "$candidate" ]; then
			actual=$(sha256_file "$candidate")
			if [ "$actual" = "$BCPROV_SHA256" ]; then
				printf '%s\n' "$candidate"
				return 0
			fi
			echo >&2 "Ignoring Bouncy Castle JAR with unexpected SHA-256: $candidate"
		fi
	done

	cache_dir=${XDG_CACHE_HOME:-${HOME:-.}/.cache}/patched-kushion
	candidate="$cache_dir/bcprov-jdk18on-${BCPROV_VERSION}.jar"
	mkdir -p "$cache_dir"
	if [ ! -f "$candidate" ] || [ "$(sha256_file "$candidate")" != "$BCPROV_SHA256" ]; then
		echo >&2 "Downloading verified Bouncy Castle ${BCPROV_VERSION} provider..."
		download "$BCPROV_URL" "$candidate.tmp"
		actual=$(sha256_file "$candidate.tmp")
		if [ "$actual" != "$BCPROV_SHA256" ]; then
			rm -f "$candidate.tmp"
			echo >&2 "Bouncy Castle SHA-256 mismatch: $actual"
			return 1
		fi
		mv -f "$candidate.tmp" "$candidate"
	fi
	printf '%s\n' "$candidate"
}

mkdir -p "$OUTPUT_DIR"
P12_KEYSTORE="$OUTPUT_DIR/package.p12"
BKS_KEYSTORE="$OUTPUT_DIR/package.keystore"
ENV_FILE="$OUTPUT_DIR/package.env"
CERT_FILE="$OUTPUT_DIR/package-certificate.pem"
FINGERPRINT_FILE="$OUTPUT_DIR/package-certificate.sha256"
SECRETS_FILE="$OUTPUT_DIR/github-actions-secrets.env"

for file in "$P12_KEYSTORE" "$BKS_KEYSTORE" "$ENV_FILE" "$CERT_FILE" "$FINGERPRINT_FILE" "$SECRETS_FILE"; do
	if [ -e "$file" ] && [ "$FORCE" != true ]; then
		echo >&2 "Refusing to overwrite $file. Use --force to rotate the identity."
		exit 1
	fi
done
rm -f "$P12_KEYSTORE" "$BKS_KEYSTORE" "$ENV_FILE" "$CERT_FILE" "$FINGERPRINT_FILE" "$SECRETS_FILE"

PASSWORD=${PACKAGE_KEY_PASSWORD:-$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')}
if [ "${#PASSWORD}" -lt 16 ]; then
	echo >&2 "PACKAGE_KEY_PASSWORD must contain at least 16 characters"
	exit 1
fi

BCPROV_PATH=$(find_bcprov)

keytool -genkeypair -noprompt \
	-storetype PKCS12 \
	-keystore "$P12_KEYSTORE" \
	-storepass "$PASSWORD" \
	-keypass "$PASSWORD" \
	-alias "$KEY_ALIAS" \
	-keyalg RSA \
	-keysize 4096 \
	-sigalg SHA256withRSA \
	-validity "$VALIDITY_DAYS" \
	-dname "$DNAME" >/dev/null

keytool -importkeystore -noprompt \
	-srckeystore "$P12_KEYSTORE" \
	-srcstoretype PKCS12 \
	-srcstorepass "$PASSWORD" \
	-srckeypass "$PASSWORD" \
	-srcalias "$KEY_ALIAS" \
	-destkeystore "$BKS_KEYSTORE" \
	-deststoretype BKS \
	-deststorepass "$PASSWORD" \
	-destkeypass "$PASSWORD" \
	-destalias "$KEY_ALIAS" \
	-providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
	-providerpath "$BCPROV_PATH" >/dev/null

keytool -exportcert -rfc \
	-keystore "$P12_KEYSTORE" \
	-storetype PKCS12 \
	-storepass "$PASSWORD" \
	-alias "$KEY_ALIAS" \
	-file "$CERT_FILE" >/dev/null

FINGERPRINT=$(keytool -list -v \
	-keystore "$P12_KEYSTORE" \
	-storetype PKCS12 \
	-storepass "$PASSWORD" \
	-alias "$KEY_ALIAS" 2>/dev/null |
	awk -F': ' '/SHA256:/{print $2; exit}')
printf '%s\n' "$FINGERPRINT" >"$FINGERPRINT_FILE"

{
	printf 'APK_PATCHER_KEYSTORE=%q\n' "$BKS_KEYSTORE"
	printf 'APK_APKSIGNER_KEYSTORE=%q\n' "$P12_KEYSTORE"
	printf 'APK_KEYSTORE_PASSWORD=%q\n' "$PASSWORD"
	printf 'APK_KEY_PASSWORD=%q\n' "$PASSWORD"
	printf 'APK_KEY_ALIAS=%q\n' "$KEY_ALIAS"
	printf 'APK_SIGNER_NAME=%q\n' "$SIGNER_NAME"
} >"$ENV_FILE"

base64_one_line() {
	base64 <"$1" | tr -d '\r\n'
}

cat >"$SECRETS_FILE" <<EOF_SECRETS
APK_PATCHER_KEYSTORE_B64=$(base64_one_line "$BKS_KEYSTORE")
APK_APKSIGNER_KEYSTORE_B64=$(base64_one_line "$P12_KEYSTORE")
APK_KEYSTORE_PASSWORD=$PASSWORD
APK_KEY_PASSWORD=$PASSWORD
APK_KEY_ALIAS=$KEY_ALIAS
APK_SIGNER_NAME=$SIGNER_NAME
EOF_SECRETS

chmod 600 "$P12_KEYSTORE" "$BKS_KEYSTORE" "$ENV_FILE" "$SECRETS_FILE"
chmod 644 "$CERT_FILE" "$FINGERPRINT_FILE"

cat <<EOF_DONE
Generated a new package-signing identity in $OUTPUT_DIR

Certificate SHA-256:
$FINGERPRINT

Local builds will read:
$ENV_FILE

GitHub Actions secret values are in:
$SECRETS_FILE

Back up the entire directory securely. Do not commit it.
EOF_DONE
