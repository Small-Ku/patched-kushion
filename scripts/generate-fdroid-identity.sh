#!/usr/bin/env bash

set -euo pipefail

umask 077

OUTPUT_DIR="signing/fdroid"
REPOSITORY=""
REPO_NAME="patched-kushion"
REPO_DESCRIPTION="Patched and externally sourced Android applications"
KEY_ALIAS="patched-kushion"
DNAME="CN=patched-kushion, OU=F-Droid Repository Signing, O=patched-kushion"
VALIDITY_DAYS=10000
FORCE=false

usage() {
	cat <<'USAGE'
Generate a new F-Droid repository-signing identity and GitHub secret values.

Usage:
  scripts/generate-fdroid-identity.sh [options]

Options:
  --output-dir DIR       Output directory (default: signing/fdroid)
  --repository OWNER/REPO
                         GitHub repository used by the canonical raw URL.
                         Inferred from GITHUB_REPOSITORY or the origin remote
                         when possible.
  --repo-name NAME       F-Droid repository display name
  --repo-description TEXT
                         F-Droid repository description
  --alias NAME           Repository signing key alias (default: patched-kushion)
  --dname NAME           X.509 distinguished name
  --force                Replace an existing local repository identity
  -h, --help             Show this help

Environment:
  FDROID_KEY_PASSWORD    Explicit repository key password; a random
                         64-character password is generated when unset
  GITHUB_REPOSITORY      OWNER/REPO fallback when --repository is omitted
USAGE
}

while (($#)); do
	case "$1" in
	--output-dir)
		OUTPUT_DIR=${2:?missing value for --output-dir}
		shift 2
		;;
	--repository)
		REPOSITORY=${2:?missing value for --repository}
		shift 2
		;;
	--repo-name)
		REPO_NAME=${2:?missing value for --repo-name}
		shift 2
		;;
	--repo-description)
		REPO_DESCRIPTION=${2:?missing value for --repo-description}
		shift 2
		;;
	--alias)
		KEY_ALIAS=${2:?missing value for --alias}
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

infer_repository() {
	local remote path
	if [ -n "${GITHUB_REPOSITORY-}" ]; then
		printf '%s\n' "$GITHUB_REPOSITORY"
		return 0
	fi

	if ! remote=$(git remote get-url origin 2>/dev/null); then
		return 1
	fi

	case "$remote" in
	https://github.com/*)
		path=${remote#https://github.com/}
		;;
	http://github.com/*)
		path=${remote#http://github.com/}
		;;
	git@github.com:*)
		path=${remote#git@github.com:}
		;;
	ssh://git@github.com/*)
		path=${remote#ssh://git@github.com/}
		;;
	*)
		return 1
		;;
	esac
	path=${path%.git}
	printf '%s\n' "$path"
}

if [ -z "$REPOSITORY" ]; then
	REPOSITORY=$(infer_repository || true)
fi
if [[ ! $REPOSITORY =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
	echo >&2 "Could not infer a GitHub OWNER/REPOSITORY. Pass --repository OWNER/REPOSITORY."
	exit 1
fi

for value in "$REPO_NAME" "$REPO_DESCRIPTION" "$KEY_ALIAS" "$DNAME"; do
	if [[ $value == *$'\n'* || $value == *$'\r'* ]]; then
		echo >&2 "Repository metadata and key names must not contain newlines"
		exit 1
	fi
done

mkdir -p "$OUTPUT_DIR"
KEYSTORE="$OUTPUT_DIR/keystore.p12"
CONFIG="$OUTPUT_DIR/config.yml"
CERT_FILE="$OUTPUT_DIR/repository-certificate.pem"
FINGERPRINT_FILE="$OUTPUT_DIR/repository-fingerprint.sha256"
SECRETS_FILE="$OUTPUT_DIR/github-actions-secrets.env"

for file in "$KEYSTORE" "$CONFIG" "$CERT_FILE" "$FINGERPRINT_FILE" "$SECRETS_FILE"; do
	if [ -e "$file" ] && [ "$FORCE" != true ]; then
		echo >&2 "Refusing to overwrite $file. Use --force to rotate the repository identity."
		exit 1
	fi
done
rm -f "$KEYSTORE" "$CONFIG" "$CERT_FILE" "$FINGERPRINT_FILE" "$SECRETS_FILE"

PASSWORD=${FDROID_KEY_PASSWORD:-$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')}
if [ "${#PASSWORD}" -lt 16 ]; then
	echo >&2 "FDROID_KEY_PASSWORD must contain at least 16 characters"
	exit 1
fi
if [[ $PASSWORD == *$'\n'* || $PASSWORD == *$'\r'* ]]; then
	echo >&2 "FDROID_KEY_PASSWORD must not contain newlines"
	exit 1
fi

keytool -genkeypair -noprompt \
	-storetype PKCS12 \
	-keystore "$KEYSTORE" \
	-storepass "$PASSWORD" \
	-keypass "$PASSWORD" \
	-alias "$KEY_ALIAS" \
	-keyalg RSA \
	-keysize 4096 \
	-sigalg SHA256withRSA \
	-validity "$VALIDITY_DAYS" \
	-dname "$DNAME" >/dev/null

keytool -exportcert -rfc \
	-keystore "$KEYSTORE" \
	-storetype PKCS12 \
	-storepass "$PASSWORD" \
	-alias "$KEY_ALIAS" \
	-file "$CERT_FILE" >/dev/null

FINGERPRINT=$(
	keytool -list -v \
		-keystore "$KEYSTORE" \
		-storetype PKCS12 \
		-storepass "$PASSWORD" \
		-alias "$KEY_ALIAS" 2>/dev/null |
		awk -F': ' '/SHA256:/{gsub(":", "", $2); print toupper($2); exit}'
)
if [[ ! $FINGERPRINT =~ ^[0-9A-F]{64}$ ]]; then
	echo >&2 "Could not extract the repository certificate SHA-256 fingerprint"
	exit 1
fi
printf '%s\n' "$FINGERPRINT" >"$FINGERPRINT_FILE"

yaml_quote() {
	local value=${1//\'/\'\'}
	printf "'%s'" "$value"
}

REPO_URL="https://raw.githubusercontent.com/${REPOSITORY}/fdroid/fdroid/repo"
{
	printf 'repo_name: '
	yaml_quote "$REPO_NAME"
	printf '\nrepo_description: '
	yaml_quote "$REPO_DESCRIPTION"
	printf '\nrepo_url: '
	yaml_quote "$REPO_URL"
	printf '\narchive_older: 0\n'
	printf 'keystore: '
	yaml_quote 'keystore.p12'
	printf '\nkeystorepass: '
	yaml_quote "$PASSWORD"
	printf '\nkeypass: '
	yaml_quote "$PASSWORD"
	printf '\nrepo_keyalias: '
	yaml_quote "$KEY_ALIAS"
	printf '\nkeydname: '
	yaml_quote "$DNAME"
	printf '\n'
} >"$CONFIG"

base64_one_line() {
	base64 <"$1" | tr -d '\r\n'
}

cat >"$SECRETS_FILE" <<EOF_SECRETS
CONFIG_YML=$(base64_one_line "$CONFIG")
KEYSTORE_P12=$(base64_one_line "$KEYSTORE")
EOF_SECRETS

chmod 600 "$KEYSTORE" "$CONFIG" "$SECRETS_FILE"
chmod 644 "$CERT_FILE" "$FINGERPRINT_FILE"

cat <<EOF_DONE
Generated a new F-Droid repository-signing identity in $OUTPUT_DIR

Repository certificate SHA-256:
$FINGERPRINT

Client repository URL:
${REPO_URL}?fingerprint=${FINGERPRINT}

GitHub Actions secret values are in:
$SECRETS_FILE

Set CONFIG_YML and KEYSTORE_P12 from that file, then run the
"Publish F-Droid repository" workflow.

Back up the entire directory securely. Do not commit it. Rotating this key
changes the repository identity for every existing F-Droid client.
EOF_DONE
