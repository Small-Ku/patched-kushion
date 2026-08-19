#!/usr/bin/env bash

set -euo pipefail

umask 077

OUTPUT_DIR="signing/package"
FORCE=false
KEY_ALIAS="patched-kushion"
SIGNER_NAME="patched-kushion"
DNAME="CN=patched-kushion, OU=Package Signing, O=patched-kushion"
VALIDITY_DAYS=10000
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
	cat <<'USAGE'
Generate a new APK package-signing identity.

Usage:
  scripts/generate-package-identity.sh [options]

Options:
  --output-dir DIR    Output directory (default: signing/package)
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

BCPROV_PATH=$("$SCRIPT_DIR/ensure-bcprov.sh")

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
