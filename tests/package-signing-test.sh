#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "${BCPROV_JAR:-}" ]; then
	BCPROV_JAR=$(BCPROV_JAR="$BCPROV_JAR" "$repo/scripts/ensure-bcprov.sh")
else
	BCPROV_JAR=$("$repo/scripts/ensure-bcprov.sh")
fi


wrong_bcprov="$tmp/not-bcprov.jar"
printf 'not bcprov\n' > "$wrong_bcprov"
if BCPROV_JAR="$wrong_bcprov" "$repo/scripts/ensure-bcprov.sh" >"$tmp/wrong-bcprov.log" 2>&1; then
	echo >&2 "ensure-bcprov accepted an explicitly supplied JAR with the wrong digest"
	exit 1
fi
grep -Fq 'is not the pinned Bouncy Castle 1.84 provider' "$tmp/wrong-bcprov.log"

BCPROV_JAR="$BCPROV_JAR" "$repo/scripts/generate-package-identity.sh" \
	--output-dir "$tmp/signing identity" \
	--alias test-identity \
	--signer test-identity >/dev/null

# shellcheck disable=SC1091
source "$tmp/signing identity/package.env"

[ -s "$APK_PATCHER_KEYSTORE" ]
[ -s "$APK_APKSIGNER_KEYSTORE" ]
[ -s "$tmp/signing identity/package-certificate.pem" ]
[ -s "$tmp/signing identity/package-certificate.sha256" ]
[ -s "$tmp/signing identity/github-actions-secrets.env" ]

keytool -list \
	-keystore "$APK_PATCHER_KEYSTORE" \
	-storetype BKS \
	-storepass "$APK_KEYSTORE_PASSWORD" \
	-alias "$APK_KEY_ALIAS" \
	-providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
	-providerpath "$BCPROV_JAR" >/dev/null

keytool -list \
	-keystore "$APK_APKSIGNER_KEYSTORE" \
	-storetype PKCS12 \
	-storepass "$APK_KEYSTORE_PASSWORD" \
	-alias "$APK_KEY_ALIAS" >/dev/null

grep -q '^APK_PATCHER_KEYSTORE_B64=' "$tmp/signing identity/github-actions-secrets.env"
grep -q '^APK_APKSIGNER_KEYSTORE_B64=' "$tmp/signing identity/github-actions-secrets.env"

keytool -exportcert \
	-keystore "$APK_PATCHER_KEYSTORE" \
	-storetype BKS \
	-storepass "$APK_KEYSTORE_PASSWORD" \
	-alias "$APK_KEY_ALIAS" \
	-providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
	-providerpath "$BCPROV_JAR" \
	-file "$tmp/bks-cert.der" >/dev/null
keytool -exportcert \
	-keystore "$APK_APKSIGNER_KEYSTORE" \
	-storetype PKCS12 \
	-storepass "$APK_KEYSTORE_PASSWORD" \
	-alias "$APK_KEY_ALIAS" \
	-file "$tmp/p12-cert.der" >/dev/null
cmp "$tmp/bks-cert.der" "$tmp/p12-cert.der"

git -C "$repo" check-ignore -q signing/package/package.keystore
git -C "$repo" check-ignore -q signing/package/package.p12
git -C "$repo" check-ignore -q signing/package/package.env
