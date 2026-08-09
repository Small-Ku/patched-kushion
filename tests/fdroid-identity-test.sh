#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

password=fdroid-test-A9z7Q5m3N1p8R6t4V2x0
FDROID_KEY_PASSWORD="$password" "$repo/scripts/generate-fdroid-identity.sh" \
	--output-dir "$tmp/fdroid identity" \
	--repository example/patched-kushion \
	--repo-name "patched-kushion test" \
	--repo-description "F-Droid signing test" \
	--alias fdroid-test \
	--dname "CN=patched-kushion test, OU=F-Droid" >/dev/null

out="$tmp/fdroid identity"
for file in \
	config.yml \
	keystore.p12 \
	repository-certificate.pem \
	repository-fingerprint.sha256 \
	github-actions-secrets.env; do
	test -s "$out/$file"
done

keytool -list \
	-keystore "$out/keystore.p12" \
	-storetype PKCS12 \
	-storepass "$password" \
	-alias fdroid-test >/dev/null

fingerprint=$(
	keytool -list -v \
		-keystore "$out/keystore.p12" \
		-storetype PKCS12 \
		-storepass "$password" \
		-alias fdroid-test 2>/dev/null |
		awk -F': ' '/SHA256:/{gsub(":", "", $2); print toupper($2); exit}'
)
test "$fingerprint" = "$(cat "$out/repository-fingerprint.sha256")"

assert_config() {
	grep -Fqx "$1" "$out/config.yml"
}
assert_config "repo_name: 'patched-kushion test'"
assert_config "repo_description: 'F-Droid signing test'"
assert_config "repo_url: 'https://raw.githubusercontent.com/example/patched-kushion/fdroid/fdroid/repo'"
assert_config "archive_older: 0"
assert_config "keystore: 'keystore.p12'"
assert_config "keystorepass: '$password'"
assert_config "keypass: '$password'"
assert_config "repo_keyalias: 'fdroid-test'"
assert_config "keydname: 'CN=patched-kushion test, OU=F-Droid'"

config_b64=$(sed -n 's/^CONFIG_YML=//p' "$out/github-actions-secrets.env")
keystore_b64=$(sed -n 's/^KEYSTORE_P12=//p' "$out/github-actions-secrets.env")
printf '%s' "$config_b64" | base64 --decode >"$tmp/config.decoded"
printf '%s' "$keystore_b64" | base64 --decode >"$tmp/keystore.decoded"
cmp "$out/config.yml" "$tmp/config.decoded"
cmp "$out/keystore.p12" "$tmp/keystore.decoded"

git -C "$repo" check-ignore -q fdroid-signing/config.yml
git -C "$repo" check-ignore -q fdroid-signing/keystore.p12
git -C "$repo" check-ignore -q fdroid-signing/github-actions-secrets.env

echo "F-Droid repository identity generator test passed"
