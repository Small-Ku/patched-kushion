#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
# Provider arrays enumerate adapters only; they are not source-selection policy.
# Normal CI first probes every configured adapter, builds source-graph.json, and
# traverses version/broad/ABI nodes from that graph. DL_SRCS/SHARED_DL_SRCS stay
# as compatibility aliases for the local one-shot build path and older tests.
SOURCE_ADAPTERS=("direct" "aptoide" "apkpure" "uptodown" "archive" "apkmirror" "apkfab")
BROAD_SOURCE_ADAPTERS=("direct" "apkmirror" "apkpure" "archive" "uptodown")
DL_SRCS=("${SOURCE_ADAPTERS[@]}")
SHARED_DL_SRCS=("${BROAD_SOURCE_ADAPTERS[@]}")
CONFIG_DL_SRCS=("direct" "uptodown" "archive" "apkmirror" "apkfab")
# Failed acquisition-time metadata requests are memoized per provider/locator so
# a WAF-blocked listing is not retried once for every missing ABI branch.
declare -A SOURCE_ACQUISITION_NEGATIVE_RESP=()
# Payload rejections are memoized by provider/version/arch/content digest for the
# current source process. A store that returns the same wrong-ABI container twice
# must not make us repeat split analysis within one DAG traversal.
declare -A SOURCE_ACQUISITION_NEGATIVE_PAYLOAD=()

source_payload_digest() {
	sha256sum "$1" 2>/dev/null | awk '{print toupper($1)}'
}

source_payload_rejection_key() {
	local provider=$1 version=$2 arch=$3 payload=$4 digest
	digest=$(source_payload_digest "$payload") || return 1
	[ -n "$digest" ] || return 1
	printf '%s|%s|%s|%s\n' "$provider" "$version" "$arch" "$digest"
}

source_payload_was_rejected() {
	local key
	key=$(source_payload_rejection_key "$@") || return 1
	[ -n "${SOURCE_ACQUISITION_NEGATIVE_PAYLOAD[$key]-}" ]
}

record_source_payload_rejection() {
	local provider=$1 version=$2 arch=$3 payload=$4 category=$5 reason=$6 key digest safe_reason
	key=$(source_payload_rejection_key "$provider" "$version" "$arch" "$payload") || return 0
	digest=${key##*|}
	SOURCE_ACQUISITION_NEGATIVE_PAYLOAD[$key]="$category:$reason"
	safe_reason=${reason//\'/}
	npr "DAG payload rejection: provider='$provider' version='$version' arch='$arch' category='$category' payloadSha256='$digest' reason='$safe_reason'"
}

APKEEP_VERSION=${APKEEP_VERSION:-1.0.0}
APKEEP_REPOSITORY=${APKEEP_REPOSITORY:-EFForg/apkeep}
APKEDITOR_VERSION=${APKEDITOR_VERSION:-1.4.9}
APKEDITOR_REPOSITORY=${APKEDITOR_REPOSITORY:-REAndroid/APKEditor}
_APKEDITOR_URL_EXPLICIT=${APKEDITOR_URL+x}
APKEDITOR_URL=${APKEDITOR_URL:-"https://github.com/REAndroid/APKEditor/releases/download/V${APKEDITOR_VERSION}/APKEditor-${APKEDITOR_VERSION}.jar"}

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$($TOML --output json --file "$1" .)
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
}
toml_get_table_names() {
	jq -r -e '.apps | to_entries[] | select(.value.build | type == "object") | .key' <<<"$__TOML__"
}
toml_get_table_main() { jq -r -e '.build // {}' <<<"$__TOML__"; }
toml_get_table() {
	local app=$1
	jq -r -e --arg app "$app" '
		.apps[$app] as $entry |
		($entry.build // {}) + {
			"app-name": ($entry."display-name" // $app),
			"pkg-name": ($entry."upstream-package" // "")
		}
	' <<<"$__TOML__"
}

load_app_catalog() {
	local file=${1:-config.toml}
	if [ ! -f "$file" ]; then abort "could not find app catalog '$file'"; fi
	__APP_CATALOG__=$($TOML --output json --file "$file" .) || abort "could not parse app catalog '$file'"
	if ! jq -e '
		."config-version" == 1 and
		(.build | type == "object") and
		(.apps | type == "object") and
		([.apps[] | ((.build | type == "object") != (.release | type == "object"))] | all) and
		([.apps[] | ."package-name" // empty] | length == (unique | length))
	' >/dev/null <<<"$__APP_CATALOG__"; then
		abort "invalid app catalog in '$file'"
	fi
}

validate_build_apps() {
	local app package upstream build_mode
	while IFS=$'\t' read -r app package upstream build_mode; do
		[ -n "$app" ] || continue
		if [ -z "$upstream" ]; then
			abort "build app '$app' is missing upstream-package"
		fi
		if ! isoneof "$build_mode" apk module both; then
			abort "build app '$app' has invalid build-mode '$build_mode'"
		fi
		if isoneof "$build_mode" apk both; then
			if [[ ! $package =~ ^de\.kwoo\.shion\.[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$ ]]; then
				abort "invalid stable package identity '$package' for '$app'"
			fi
		fi
	done < <(jq -r '
		.apps | to_entries[] |
		select(.value.build | type == "object") |
		[.key, (.value."package-name" // ""), (.value."upstream-package" // ""), (.value.build."build-mode" // "apk")] |
		@tsv
	' <<<"$__APP_CATALOG__")
}

package_identity_for_app() {
	local app=$1
	jq -r -e --arg app "$app" '
		.apps[$app] |
		select(.build | type == "object") |
		."package-name" |
		select(type == "string" and length > 0)
	' <<<"$__APP_CATALOG__"
}

remove_managed_patch_selection() {
	local -n args_ref=$1
	local patch_name=$2 index value
	local enable_double disable_double enable_single disable_single
	[ -n "$patch_name" ] || return 0
	enable_double="-e \"$patch_name\""
	disable_double="-d \"$patch_name\""
	enable_single="-e '$patch_name'"
	disable_single="-d '$patch_name'"
	for index in "${!args_ref[@]}"; do
		value=${args_ref[$index]}
		value=${value//"$enable_double"/}
		value=${value//"$disable_double"/}
		value=${value//"$enable_single"/}
		value=${value//"$disable_single"/}
		args_ref[$index]=$value
	done
}

find_package_identity_patch() {
	local list_patches=$1 patch_name
	# Morphe renamed the universal package-name patch to "Clone app".
	# Prefer the current name while keeping compatibility with older bundles.
	for patch_name in "Clone app" "Clone" "Change package name"; do
		if grep -Fqx "Name: $patch_name" <<<"$list_patches"; then
			printf '%s\n' "$patch_name"
			return 0
		fi
	done
	return 1
}

configure_nonroot_app_identity() {
	local build_mode=$1 package_name_patch=$2 package_identity=$3 upstream_package=$4 user_patcher_args=$5
	local -n output_args=$6
	[ -n "$package_identity" ] || return 0
	if [[ $user_patcher_args =~ (^|[[:space:]])-OpackageName(=|[[:space:]]) ]] || \
		{ [ -n "$package_name_patch" ] && [[ $user_patcher_args == *"$package_name_patch"* ]]; }; then
		epr "Do not manage the package name manually for a target managed in config.toml"
		return 1
	fi
	if [ "$build_mode" = module ]; then
		[ -z "$package_name_patch" ] || output_args+=("-d \"${package_name_patch}\"")
		return 0
	fi
	if [ -z "$package_name_patch" ]; then
		if [ "$package_identity" = "$upstream_package" ]; then
			return 0
		fi
		epr "Cannot apply stable package identity '$package_identity': the selected patch bundle lacks a compatible Clone app/package-name patch"
		return 1
	fi
	output_args+=("-e \"${package_name_patch}\"" "-OpackageName=$package_identity")
}

apply_auxiliary_package_identity() {
	local input_apk=$1 output_apk=$2 package_identity=$3 patch_name=$4 cli_jar=$5 patches_jar=$6
	[ -n "$package_identity" ] || { epr "Auxiliary package identity is empty"; return 1; }
	[ -n "$patch_name" ] || { epr "Auxiliary package identity patch is empty"; return 1; }
	patch_apk "$input_apk" "$output_apk" 		"--exclusive -e \"${patch_name}\" -OpackageName=${package_identity}" 		"$cli_jar" "$patches_jar"
}

resolve_android_build_tool() {
	local tool=$1 override_name=$2 candidate sdk_root override
	override=${!override_name-}
	if [ -n "$override" ] && [ -x "$override" ]; then
		printf '%s\n' "$override"
		return 0
	fi
	if candidate=$(command -v "$tool" 2>/dev/null) && [ -x "$candidate" ]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	for sdk_root in "${ANDROID_HOME-}" "${ANDROID_SDK_ROOT-}" "${HOME-}/Android/Sdk"; do
		[ -n "$sdk_root" ] || continue
		[ -d "$sdk_root/build-tools" ] || continue
		candidate=$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 -type f -name "$tool" -perm -u+x -print 2>/dev/null | sort -V | tail -1)
		if [ -n "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

resolve_zipalign() {
	resolve_android_build_tool zipalign ZIPALIGN
}

resolve_apksigner() {
	resolve_android_build_tool apksigner APKSIGNER
}

apksigner_jar_fallback() {
	local candidate=${APKSIGNER_JAR:-${BIN_DIR}/apksigner.jar}
	# Backward compatibility for local callers which historically pointed
	# APKSIGNER at the bundled jar rather than an SDK executable.
	if [ ! -f "$candidate" ] && [ -n "${APKSIGNER-}" ] && [ -f "$APKSIGNER" ]; then
		candidate=$APKSIGNER
	fi
	[ -f "$candidate" ] || return 1
	printf '%s\n' "$candidate"
}

run_apksigner() {
	local executable jar
	if executable=$(resolve_apksigner); then
		"$executable" "$@"
		return $?
	fi
	jar=$(apksigner_jar_fallback) || {
		epr "apksigner was not found in APKSIGNER, PATH, Android SDK build-tools, or the bundled fallback"
		return 1
	}
	java -jar "$jar" "$@"
}

resolve_aapt2() {
	local candidate arch
	if [ -n "${AAPT2-}" ] && [ -x "$AAPT2" ]; then
		printf '%s\n' "$AAPT2"
		return 0
	fi
	if candidate=$(command -v aapt2 2>/dev/null) && [ -x "$candidate" ]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	candidate="${BIN_DIR}/aapt2/aapt2-${arch}"
	if [ -x "$candidate" ]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	resolve_android_build_tool aapt2 AAPT2
}

verify_apk_package_identity() {
	local apk=$1 expected=$2 output actual aapt2
	[ -n "$expected" ] || return 0
	if ! aapt2=$(resolve_aapt2); then
		epr "Could not inspect patched APK package identity '$apk': aapt2 was not found in AAPT2, PATH, bundled prebuilts, or Android SDK build-tools"
		return 1
	fi
	if ! output=$("$aapt2" dump badging "$apk" 2>&1); then
		epr "Could not inspect patched APK package identity '$apk' with '$aapt2': $output"
		return 1
	fi
	actual=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$output" | head -1)
	if [ "$actual" != "$expected" ]; then
		epr "Patched APK package identity mismatch: expected '$expected', got '${actual:-unknown}'"
		return 1
	fi
}

patch_notice_file() {
	case "$1" in
	MorpheApp/morphe-patches) printf '%s\n' "$CWD/NOTICE" ;;
	*) return 1 ;;
	esac
}

patch_notice_archive_name() {
	case "$1" in
	MorpheApp/morphe-patches) printf '%s\n' 'MORPHE_NOTICE.txt' ;;
	*) return 1 ;;
	esac
}

sign_apk() {
	local input=$1 output=$2 pass_dir store_pass_file key_pass_file op
	pass_dir=$(mktemp -d -p "$TEMP_DIR")
	store_pass_file="$pass_dir/storepass"
	key_pass_file="$pass_dir/keypass"
	printf '%s\n' "$APK_KEYSTORE_PASSWORD" >"$store_pass_file"
	printf '%s\n' "$APK_KEY_PASSWORD" >"$key_pass_file"
	chmod 600 "$store_pass_file" "$key_pass_file"
	if ! op=$(run_apksigner sign \
		--ks "$APK_APKSIGNER_KEYSTORE" \
		--ks-pass "file:$store_pass_file" \
		--key-pass "file:$key_pass_file" \
		--ks-key-alias "$APK_KEY_ALIAS" \
		--out "$output" "$input" 2>&1); then
		rm -rf "$pass_dir"
		rm -f "$output" "${output}.idsig"
		epr "apksigner error: $op"
		return 1
	fi
	rm -rf "$pass_dir"
	rm -f "${output}.idsig"
}

verify_apk_signature() {
	local apk=$1 op
	if ! op=$(run_apksigner verify --verbose --print-certs "$apk" 2>&1); then
		epr "apksigner verification error for '$apk': $op"
		return 1
	fi
}

finalize_apk() {
	local input=$1 output=$2 zipalign aligned signed op
	if ! zipalign=$(resolve_zipalign); then
		epr "Could not finalize '$input': zipalign was not found in ZIPALIGN, PATH, or Android SDK build-tools"
		return 1
	fi

	aligned=$(mktemp -p "$TEMP_DIR" apk-aligned.XXXXXX.apk)
	signed=$(mktemp -p "$TEMP_DIR" apk-signed.XXXXXX.apk)
	rm -f "$aligned" "$signed"

	if ! op=$("$zipalign" -P 16 -f 4 "$input" "$aligned" 2>&1); then
		rm -f "$aligned" "$signed"
		epr "zipalign error for '$input': $op"
		return 1
	fi
	if ! sign_apk "$aligned" "$signed"; then
		rm -f "$aligned" "$signed"
		return 1
	fi
	if ! verify_apk_signature "$signed"; then
		rm -f "$aligned" "$signed"
		return 1
	fi
	if ! op=$("$zipalign" -c -P 16 4 "$signed" 2>&1); then
		rm -f "$aligned" "$signed"
		epr "Final APK alignment verification failed for '$signed': $op"
		return 1
	fi

	mv -f "$signed" "$output"
	rm -f "$aligned"
}

embed_patch_notice_in_apk() {
	local apk=$1 patches_src=$2 notice archive_name stage apk_abs
	if ! notice=$(patch_notice_file "$patches_src"); then return 0; fi
	archive_name=$(patch_notice_archive_name "$patches_src") || return 1
	[ -s "$notice" ] || { epr "Required patch notice is missing: $notice"; return 1; }

	stage=$(mktemp -d -p "$TEMP_DIR")
	mkdir -p "$stage/assets/patched-kushion/notices"
	cp -f "$notice" "$stage/assets/patched-kushion/notices/$archive_name"
	case "$apk" in
	/*) apk_abs=$apk ;;
	*) apk_abs="$CWD/$apk" ;;
	esac
	if ! (cd "$stage" && zip -q "$apk_abs" "assets/patched-kushion/notices/$archive_name"); then
		rm -rf "$stage"
		epr "Could not embed required patch notice in '$apk'"
		return 1
	fi
	rm -rf "$stage"
}

copy_patch_notice_to_module() {
	local patches_src=$1 module_dir=$2 notice archive_name
	if ! notice=$(patch_notice_file "$patches_src"); then return 0; fi
	archive_name=$(patch_notice_archive_name "$patches_src") || return 1
	[ -s "$notice" ] || { epr "Required patch notice is missing: $notice"; return 1; }
	cp -f "$notice" "$module_dir/$archive_name"
}

toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	if [ "${GITHUB_REPOSITORY-}" ]; then
		case "${PATCHED_KUSHION_ERROR_ANNOTATION:-error}" in
			none|plain) printf >&2 'utils.sh [-] %s\n' "$1" ;;
			notice) printf >&2 '::notice::utils.sh [-] %s\n' "$1" ;;
			warning) printf >&2 '::warning::utils.sh [-] %s\n' "$1" ;;
			*) printf >&2 '::error::utils.sh [-] %s\n' "$1" ;;
		esac
	else
		echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	fi
}
npr() {
	# Routine probe/fallback diagnostics are intentionally ordinary log lines.
	# Turning every informational message into a GitHub notice duplicates the
	# line in the run metadata and made large DAG runs difficult to inspect or
	# download. Callers that need an annotation should use anpr explicitly.
	if [ "${GITHUB_REPOSITORY-}" ]; then
		printf >&2 'utils.sh [i] %s\n' "$1"
	else
		echo >&2 -e "\033[0;36m[i] ${1}\033[0m"
	fi
}
anpr() {
	if [ "${GITHUB_REPOSITORY-}" ]; then
		printf >&2 '::notice::utils.sh [i] %s\n' "$1"
	else
		npr "$1"
	fi
}
wpr() {
	if [ "${GITHUB_REPOSITORY-}" ]; then
		printf >&2 '::warning::utils.sh [!] %s\n' "$1"
	else
		echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	fi
}
request_failure() {
	case "${REQUEST_FAILURE_LEVEL:-error}" in
	notice) npr "$1" ;;
	warning) wpr "$1" ;;
	*) epr "$1" ;;
	esac
}

_clean_tmp() {
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*tmp_* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./*-temporary-files
}

abort() {
	epr "ABORT: ${1-}"
	_clean_tmp
	trap - SIGTERM SIGINT EXIT
	# Normal builds terminate the whole process group so parallel patch workers
	# cannot leak after a fatal error. CI probe stages deliberately capture a
	# failed candidate and continue the DAG; in that mode the wrapper must survive
	# long enough to record status and upload the diagnostic log.
	if [ "${PATCHED_KUSHION_CAPTURE_FAILURE:-false}" != true ]; then
		kill -9 -- -$$ 2>/dev/null
	fi
	exit 1
}

resolve_repo_path() {
	case "$1" in
	/*) printf '%s\n' "$1" ;;
	*) printf '%s/%s\n' "$CWD" "$1" ;;
	esac
}

load_package_identity() {
	local env_file=${APK_SIGNING_ENV_FILE:-signing/package/package.env}
	env_file=$(resolve_repo_path "$env_file")
	if [ -f "$env_file" ]; then
		set -a
		# shellcheck disable=SC1090
		source "$env_file"
		set +a
	fi

	APK_PATCHER_KEYSTORE=$(resolve_repo_path "${APK_PATCHER_KEYSTORE:-signing/package/package.keystore}")
	APK_APKSIGNER_KEYSTORE=$(resolve_repo_path "${APK_APKSIGNER_KEYSTORE:-signing/package/package.p12}")
	APK_KEY_ALIAS=${APK_KEY_ALIAS:-patched-kushion}
	APK_SIGNER_NAME=${APK_SIGNER_NAME:-patched-kushion}
	APK_KEY_PASSWORD=${APK_KEY_PASSWORD:-${APK_KEYSTORE_PASSWORD-}}

	local missing=()
	[ -s "$APK_PATCHER_KEYSTORE" ] || missing+=("$APK_PATCHER_KEYSTORE")
	[ -s "$APK_APKSIGNER_KEYSTORE" ] || missing+=("$APK_APKSIGNER_KEYSTORE")
	[ -n "${APK_KEYSTORE_PASSWORD-}" ] || missing+=("APK_KEYSTORE_PASSWORD")
	[ -n "${APK_KEY_PASSWORD-}" ] || missing+=("APK_KEY_PASSWORD")
	[ -n "$APK_KEY_ALIAS" ] || missing+=("APK_KEY_ALIAS")
	if ((${#missing[@]})); then
		abort "Package-signing identity is incomplete: ${missing[*]}. Run ./scripts/generate-package-identity.sh or configure the GitHub Actions secrets documented in docs/package-signing.md."
	fi

	export APK_PATCHER_KEYSTORE APK_APKSIGNER_KEYSTORE APK_KEYSTORE_PASSWORD APK_KEY_PASSWORD APK_KEY_ALIAS APK_SIGNER_NAME
}
java() {
	if [ "${JAVA_HOME_21_X64-}" ]; then
		env -i JAVA_HOME="$JAVA_HOME_21_X64" "$JAVA_HOME_21_X64"/bin/java --enable-native-access=ALL-UNNAMED "$@"
	else
		env -i java --enable-native-access=ALL-UNNAMED "$@"
	fi
}

patched_kushion_cache_dir() {
	printf '%s\n' "${PATCHED_KUSHION_CACHE_DIR:-${TEMP_DIR}/cache}"
}

get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	pr "Getting prebuilts (${patches_src%/*})" >&2
	local cl_dir=${patches_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-patcher
	mkdir -p "$cl_dir"
	: >"${cl_dir}/changelog.md"

	local src_ver tag src ver releases_url resp tag_name matches matches_new asset name url digest expected actual
	local cache_root dir file
	cache_root=$(patched_kushion_cache_dir)
	for src_ver in "Patches $patches_src $patches_ver" "CLI $cli_src $cli_ver"; do
		set -- $src_ver
		tag=$1 src=$2 ver=${3-}
		releases_url="https://api.github.com/repos/${src}/releases"
		if [ "$ver" = dev ]; then
			resp=$(gh_req "$releases_url" -) || return 1
			tag_name=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
			resp=$(jq -c --arg tag "$tag_name" 'map(select(.tag_name == $tag)) | .[0] // empty' <<<"$resp")
			[ -n "$resp" ] || return 1
		elif [ "$ver" = latest ]; then
			resp=$(gh_req "${releases_url}/latest" -) || return 1
			tag_name=$(jq -r '.tag_name // empty' <<<"$resp")
		else
			resp=$(gh_req "${releases_url}/tags/${ver}" -) || return 1
			tag_name=$(jq -r '.tag_name // empty' <<<"$resp")
		fi
		[ -n "$tag_name" ] || { epr "Could not resolve release tag for ${src} ${ver}"; return 1; }

		if [ "$tag" = Patches ]; then
			matches=$(jq -e '.assets | map(select(.name | endswith(".mpp")))' <<<"$resp") || return 1
		else
			matches=$(jq -e '.assets | map(select(.name | endswith(".jar")))' <<<"$resp") || return 1
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				matches_new=$(jq -e 'map(select((.name | endswith("-all.jar")) and (.name | contains("-dev") | not)))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then matches=$matches_new; fi
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			matches_new=$(jq -e 'map(select(.name | contains("-dev") | not))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then matches=$matches_new; fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
			epr "No ${tag,,} asset was found for ${src} ${tag_name}"
			return 1
		elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
			wpr "More than 1 ${tag,,} asset was found for ${src} ${tag_name}; using the first one"
		fi
		asset=$(jq -c '.[0]' <<<"$matches")
		name=$(jq -r '.name' <<<"$asset")
		url=$(jq -r '.url' <<<"$asset")
		digest=$(jq -r '.digest // empty' <<<"$asset")

		# Only persist executable patch assets when GitHub exposes an immutable
		# SHA-256 digest. Older releases without a digest remain job-local.
		if [[ $digest =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
			expected=${digest#sha256:}; expected=${expected,,}
			dir="${cache_root}/patches/${src//\//_}/${tag_name}"
		else
			expected=""
			dir="${TEMP_DIR}/${src//\//_}-uncached/${tag_name}"
		fi
		mkdir -p "$dir"
		file="${dir}/${name}"
		if [ -f "$file" ] && [ -n "$expected" ]; then
			actual=$(sha256sum "$file" | awk '{print tolower($1)}')
			if [ "$actual" != "$expected" ]; then
				wpr "Discarding cached ${tag,,} asset with an unexpected digest: $name"
				rm -f "$file"
			fi
		fi
		if [ ! -f "$file" ]; then
			gh_dl "$file" "$url" >&2 || return 1
		fi
		if [ -n "$expected" ]; then
			actual=$(sha256sum "$file" | awk '{print tolower($1)}')
			if [ "$actual" != "$expected" ]; then
				epr "${tag} asset SHA-256 mismatch for ${src}/${name}"
				rm -f "$file"
				return 1
			fi
		fi
		echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
		if [ "$tag" = Patches ]; then
			echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\\n" >>"${cl_dir}/changelog.md"
		fi
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER_JAR="${APKSIGNER_JAR:-${BIN_DIR}/apksigner.jar}"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	if [ -z "${AAPT2-}" ] && [ -x "${BIN_DIR}/aapt2/aapt2-${arch}" ]; then
		AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	fi
	TOML="${BIN_DIR}/toml/tq-${arch}"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [[ -v sources["$PATCHES_SRC/$PATCHES_VER"] ]]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then upped+=("$table_name"); fi
		else
			sources["$PATCHES_SRC/$PATCHES_VER"]=0
			local releases_url="https://api.github.com/repos/${PATCHES_SRC}/releases"
			if [ "$PATCHES_VER" = "dev" ]; then
				last_patches=$(gh_req "$releases_url" - | jq -e -r '.[0]') || continue
			elif [ "$PATCHES_VER" = "latest" ]; then
				last_patches=$(gh_req "$releases_url/latest" -) || continue
			else
				last_patches=$(gh_req "$releases_url/tags/${PATCHES_VER}" -) || continue
			fi
			if ! last_patches=$(jq -e -r '.assets[] | select(.name | endswith(".mpp")) | .name' <<<"$last_patches"); then
				abort "config_update error: '$last_patches'"
			fi
			if [ "$last_patches" ]; then
				if ! OP=$(grep "^Patches: ${PATCHES_SRC%%/*}/" build.md | grep -m1 "$last_patches"); then
					sources["$PATCHES_SRC/$PATCHES_VER"]=1
					prcfg=true
					upped+=("$table_name")
				else
					echo "$OP" >>"$TEMP_DIR"/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq ".apps |= with_entries(select(${query} or (.value.release | type == \"object\")))" <<<"$__TOML__"
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	local dlp="$op"
	if [ "$op" != - ]; then
		if [ -f "$op" ]; then return; fi
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
	fi
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 1 --fail -s -S "$@" "$ip" -o "$dlp"; then
		request_failure "Request failed: $ip"
		if [ "$dlp" != - ]; then rm -f "$dlp"; fi
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
}
req() {
	local ip=$1 op=$2
	shift 2
	_req "$ip" "$op" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0" "$@"
}
apkmirror_req() {
	local url=$1 output=$2 referer=${3:-https://www.apkmirror.com/}
	req "$url" "$output" -H "Referer: $referer" -H "Accept-Language: en-US,en;q=0.9"
}
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

ensure_apkeep() {
	local override=${APKEEP_BIN:-} arch asset bin release asset_meta url digest expected actual
	if [ -n "$override" ] && [ -x "$override" ]; then
		APKEEP=$override
		return 0
	fi
	if [ -n "${APKEEP-}" ] && [ -x "$APKEEP" ]; then return 0; fi

	arch=$(uname -m)
	case "$arch" in
		x86_64|amd64) asset=apkeep-x86_64-unknown-linux-gnu ;;
		aarch64|arm64) asset=apkeep-aarch64-unknown-linux-gnu ;;
		armv7l|armv7*) asset=apkeep-armv7-unknown-linux-gnueabihf ;;
		*)
			npr "apkeep has no configured prebuilt for host architecture '$arch'"
			return 1
			;;
	esac
	local cache_root
	cache_root=$(patched_kushion_cache_dir)
	bin="${cache_root}/tools/apkeep/${APKEEP_VERSION}/${asset}"

	# Resolve the pinned GitHub release metadata so the release asset digest is
	# checked before an automatically downloaded helper is executed.
	release=$(gh_req "https://api.github.com/repos/${APKEEP_REPOSITORY}/releases/tags/${APKEEP_VERSION}" -) || return 1
	asset_meta=$(jq -e --arg asset "$asset" '.assets[] | select(.name == $asset)' <<<"$release") || {
		npr "apkeep ${APKEEP_VERSION} has no release asset '$asset'"
		return 1
	}
	url=$(jq -r '.browser_download_url // empty' <<<"$asset_meta")
	digest=$(jq -r '.digest // empty' <<<"$asset_meta")
	[ -n "$url" ] || return 1
	if [[ ! $digest =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
		npr "apkeep ${APKEEP_VERSION} release metadata does not expose a SHA-256 digest for '$asset'"
		return 1
	fi
	expected=${digest#sha256:}
	expected=${expected,,}

	mkdir -p "$(dirname "$bin")"
	if [ -f "$bin" ]; then
		actual=$(sha256sum "$bin" | awk '{print tolower($1)}')
		if [ "$actual" != "$expected" ]; then
			npr "Removing cached apkeep '$bin' with unexpected SHA-256"
			rm -f "$bin"
		fi
	fi
	if [ ! -f "$bin" ]; then
		gh_dl "$bin" "$url" || return 1
	fi
	actual=$(sha256sum "$bin" | awk '{print tolower($1)}')
	if [ "$actual" != "$expected" ]; then
		epr "Downloaded apkeep SHA-256 mismatch: expected $expected, got $actual"
		rm -f "$bin"
		return 1
	fi
	chmod +x "$bin"
	APKEEP=$bin
}

log() { echo -e "$1  " >>"build.md"; }
get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -s -t- -k1,1Vr <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 _exc_sel=$4 _exclusive=$5 # TODO: resolve using all of these
	local op
	if [ "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi
	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name") || return 1
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | sed '1d' | awk '{$1=$1}1')
	if [ "$op" = "Any" ]; then return; fi
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		if grep -Fq "$pkg_name" <<<"$list_patches"; then
			return
		else
			abort "No patches found for '$pkg_name' in patches '$patches_jar'"
		fi
	fi
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | get_highest_ver || return 1
}

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 op
	if op=$(java -jar "$cli_jar" list-versions --patches "$patches_jar" --filter-package-names "$pkg_name" 2>&1); then
		echo "$op"
		return
	fi
	epr "Could not list versions ($pkg_name) $cli_jar: '$op'"
	return 1
}
patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 op
	if ! op=$(java -jar "$cli_jar" list-patches --patches "$patches_jar" --filter-package-name "$pkg_name" --with-versions --with-packages 2>&1); then
		epr "Could not get patches list ($pkg_name) $cli_jar: '$op'"
		return 1
	fi
	echo "$op"
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

record_optional_variant_skip() {
	local reason=$1 marker
	[ "${BUILD_OPTIONAL_VARIANT:-false}" = true ] || return 1
	mkdir -p "$BUILD_DIR"
	marker="$BUILD_DIR/skip.json"
	jq -n \
		--arg target "${BUILD_TARGET:-}" \
		--arg arch "${BUILD_ARCH:-}" \
		--arg mode "${BUILD_MODE:-}" \
		--arg reason "$reason" \
		'{schemaVersion:1,target:$target,arch:$arch,mode:$mode,reason:$reason}' \
		>"$marker"
	if [ "${BUILD_STOCK_ONLY:-false}" = true ] && [ -n "${BUILD_STOCK_OUTPUT_DIR:-}" ]; then
		mkdir -p "$BUILD_STOCK_OUTPUT_DIR"
		cp -f "$marker" "$BUILD_STOCK_OUTPUT_DIR/skip.json"
	fi
	if [ "${BUILD_PATCH_ONLY:-false}" = true ] && [ -n "${BUILD_PATCH_OUTPUT_DIR:-}" ]; then
		mkdir -p "$BUILD_PATCH_OUTPUT_DIR"
		cp -f "$marker" "$BUILD_PATCH_OUTPUT_DIR/skip.json"
	fi
	npr "Optional variant unavailable: $reason"
}

source_coverage_json() {
	local requested_json=$1 available_json=$2
	jq -cn --argjson requested "$requested_json" --argjson available "$available_json" '
		def normalized:
			if type == "string" then {arch:., sourcePriority:"required"}
			else . + {sourcePriority:(.sourcePriority // (if (.optional // false) then "desired" else "required" end))}
			end;
		[$requested[] | normalized] as $items
		| {
			required: [$items[] | select(.sourcePriority == "required") | .arch],
			desired:  [$items[] | select(.sourcePriority == "desired")  | .arch],
			optional: [$items[] | select(.sourcePriority == "optional") | .arch],
			available: $available
		  }
		| .missingRequired = (.required - .available)
		| .missingDesired = (.desired - .available)
		| .missingOptional = (.optional - .available)
	'
}

annotate_source_coverage() {
	local manifest=$1 requested_json=$2 available_json=$3 coverage
	coverage=$(source_coverage_json "$requested_json" "$available_json") || return 1
	jq --argjson coverage "$coverage" '.coverage=$coverage' "$manifest" >"${manifest}.tmp" && mv -f "${manifest}.tmp" "$manifest"
}

prepare_generic_shared_payload() {
	local source_name=$1 payload=$2 pkg_name=$3 version=$4 arches_json=$5 out=$6
	local sig_op meta_tmp inventory_tmp format trust_class provenance_family provenance_domain arch optional source_priority
	local available_arches=() required_missing=false branch_dir
	meta_tmp="${payload}.source.json"
	format=$(jq -r '.format // empty' "$meta_tmp" 2>/dev/null || :)
	trust_class=$(source_trust_class "$source_name")
	provenance_family=$(source_provenance_family "$source_name")
	provenance_domain=$(source_provenance_domain "$source_name" "${args[${source_name}_dlurl]-}")
	rm -rf "$out"
	mkdir -p "$out"

	if [ "$format" = APK ]; then
		if ! sig_op=$(check_sig "$payload" "$pkg_name" "$source_name" 2>&1); then
			epr "Shared source signature mismatch '$payload': $sig_op"
			return 1
		fi
		local standalone_arches
		standalone_arches=$(standalone_apk_build_arches "$payload") || return 1
		mkdir -p "$out/branches"
		while IFS=$'\t' read -r arch optional source_priority; do
			[ -n "$arch" ] || continue
			branch_dir="$out/branches/$arch"
			mkdir -p "$branch_dir"
			local available=false
			grep -qx "$arch" <<<"$standalone_arches" && available=true
			if [ "$available" = true ]; then
				cp -f "$payload" "$branch_dir/stock.apk"
				jq -n --arg arch "$arch" --arg sourceName "$source_name" --arg trustClass "$trust_class" \
					--arg provenanceFamily "$provenance_family" --arg provenanceDomain "$provenance_domain" \
					'{schemaVersion:2,available:true,arch:$arch,sourceName:$sourceName,format:"APK",trustClass:$trustClass,sourceProvenanceFamily:$provenanceFamily,sourceProvenanceDomain:$provenanceDomain,signerVerified:true,reusedBroadPayload:true,derivation:"standalone"}' \
					>"$branch_dir/branch.json"
				available_arches+=("$arch")
			else
				jq -n --arg arch "$arch" --argjson optional "$optional" \
					'{schemaVersion:2,available:false,arch:$arch,optional:$optional,reason:"Standalone APK runtime compatibility does not provide a derivable branch without split boundaries"}' \
					>"$branch_dir/branch.json"
				[ "$source_priority" = required ] && required_missing=true
			fi
		done < <(jq -r '.[] | if type == "string" then [.,false,"required"] else [.arch,(.optional // false),(.sourcePriority // (if (.optional // false) then "desired" else "required" end))] end | @tsv' <<<"$arches_json")
		local available_json
		available_json=$(printf '%s\n' "${available_arches[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
		jq -n --arg target "${BUILD_TARGET:-}" --arg package "$pkg_name" --arg version "$version" \
			--arg sourceName "$source_name" --arg trustClass "$trust_class" --arg provenanceFamily "$provenance_family" \
			--arg provenanceDomain "$provenance_domain" --argjson requestedArches "$arches_json" --argjson available "$available_json" \
			--argjson ready "$([ "$required_missing" = true ] && echo false || echo true)" \
			'{schemaVersion:2,status:(if $ready then "ready" else "unavailable" end),shared:$ready,strategy:"branches",target:$target,packageName:$package,version:$version,sourceName:$sourceName,trustClass:$trustClass,sourceProvenanceFamily:$provenanceFamily,sourceProvenanceDomain:$provenanceDomain,signerPinRequired:($sourceName != "direct"),signerVerified:true,requestedArches:$requestedArches,availableBuildArches:$available,coverage:{required:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch]),available:$available,missingRequired:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch] - $available)},selection:{format:"APK",reusedBroadPayload:true}}' \
			>"$out/source.json"
		annotate_source_coverage "$out/source.json" "$arches_json" "$available_json" || return 1
		[ "$required_missing" != true ]
		return
	fi

	if ! python3 "$CWD/scripts/stock_bundle.py" partition --bundle "$payload" --output-root "$out" >/dev/null; then
		npr "Downloaded '${source_name}' container could not be partitioned"
		return 1
	fi
	local partition_available pre_coverage
	partition_available=$(jq -c '.availableBuildArches // []' "$out/partition.json") || return 1
	pre_coverage=$(source_coverage_json "$arches_json" "$partition_available") || return 1
	if ! jq -e '(.missingRequired | length) == 0' >/dev/null <<<"$pre_coverage"; then
		npr "Shared '${source_name}' container does not cover every required architecture"
		return 1
	fi
	while IFS= read -r -d '' split_apk; do
		if ! sig_op=$(check_sig "$split_apk" "$pkg_name" "$source_name" 2>&1); then
			epr "Shared source signature mismatch '$split_apk': $sig_op"
			return 1
		fi
	done < <(find "$out/common" "$out/abi" -type f -name '*.apk' -print0)

	inventory_tmp="${payload}.inventory.json"
	jq -n \
		--arg target "${BUILD_TARGET:-}" --arg package "$pkg_name" --arg version "$version" \
		--arg sourceName "$source_name" --arg trustClass "$trust_class" \
		--arg provenanceFamily "$provenance_family" --arg provenanceDomain "$provenance_domain" \
		--argjson requestedArches "$arches_json" --slurpfile partition "$out/partition.json" \
		--slurpfile selection "$meta_tmp" \
		--slurpfile inventory "$([ -f "$inventory_tmp" ] && echo "$inventory_tmp" || echo /dev/null)" \
		'{schemaVersion:2,status:"ready",shared:true,strategy:"partition",target:$target,packageName:$package,version:$version,sourceName:$sourceName,trustClass:$trustClass,sourceProvenanceFamily:$provenanceFamily,sourceProvenanceDomain:$provenanceDomain,signerPinRequired:($sourceName != "direct"),signerVerified:true,requestedArches:$requestedArches,availableBuildArches:($partition[0].availableBuildArches // []),coverage:{required:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch]),available:($partition[0].availableBuildArches // []),missingRequired:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch] - ($partition[0].availableBuildArches // []))},selection:($selection[0] // {}),inventory:($inventory[0] // [])}' \
		>"$out/source.json"
	annotate_source_coverage "$out/source.json" "$arches_json" "$partition_available" || return 1
}

source_candidate_score() {
	local manifest=$1 source_name=$2 desired optional coverage partition_bonus source_bonus artifacts bytes size_penalty
	desired=$(jq -r '((.coverage.desired // []) - (.coverage.missingDesired // [])) | length' "$manifest")
	optional=$(jq -r '((.coverage.optional // []) - (.coverage.missingOptional // [])) | length' "$manifest")
	coverage=$(jq -r '(((.coverage.required // []) | length) - ((.coverage.missingRequired // []) | length)) + (((.coverage.desired // []) | length) - ((.coverage.missingDesired // []) | length)) + (((.coverage.optional // []) | length) - ((.coverage.missingOptional // []) | length))' "$manifest")
	[ "$coverage" -gt 0 ] || return 1
	case "$(jq -r '.strategy // "partition"' "$manifest")" in
		partition) partition_bonus=200 ;;
		branches) partition_bonus=100 ;;
		*) partition_bonus=0 ;;
	esac
	case "$source_name" in
		direct) source_bonus=50 ;;
		apkmirror) source_bonus=40 ;;
		apkpure) source_bonus=30 ;;
		archive) source_bonus=20 ;;
		uptodown) source_bonus=10 ;;
		*) source_bonus=0 ;;
	esac
	artifacts=$(jq -r '.downloadPlan.artifactCount // .selection.artifactCount // 1' "$manifest")
	[[ $artifacts =~ ^[0-9]+$ ]] || artifacts=1
	bytes=$(du -sb "$(dirname "$manifest")" 2>/dev/null | awk '{print $1}' || echo 0)
	[[ $bytes =~ ^[0-9]+$ ]] || bytes=0
	size_penalty=$((bytes / 1048576))
	# Required coverage is gated before scoring. Desired auto branches dominate,
	# then true optional coverage, reusable split/partition structure, fewer
	# downloads, source trust preference, and finally transferred size.
	echo $((desired * 1000000000 + optional * 10000000 + coverage * 1000000 + partition_bonus * 1000 - artifacts * 100 + source_bonus - size_penalty))
}

prepare_shared_stock_source() {
	local pkg_name=$1 version=$2 dpi=$3 arches_json=$4 graph=${5:-}
	local out=${BUILD_SOURCE_OUTPUT_DIR:-} payload source_name candidate_out candidate_score best_score=-1 best_dir=""
	local source_order=()
	[ -n "$out" ] || { epr "BUILD_SOURCE_OUTPUT_DIR is required for source-only builds"; return 1; }
	rm -rf "$out"
	mkdir -p "$out"

	if [ -n "$graph" ] && [ -f "$graph" ]; then
		mapfile -t source_order < <(source_graph_sources "$graph" "$version" broad)
	else
		source_order=("${SHARED_DL_SRCS[@]}")
	fi
	for source_name in "${source_order[@]}"; do
		[ -n "${args[${source_name}_dlurl]-}" ] || continue
		candidate_out="$TEMP_DIR/shared-candidate-${source_name}"
		rm -rf "$candidate_out"
		mkdir -p "$candidate_out"

		if [ "$source_name" = apkmirror ]; then
			pr "Looking for reusable APKMirror release variants"
			if ! prepare_apkmirror_planned_source "$pkg_name" "$version" "$dpi" "$arches_json" "$candidate_out"; then
				npr "No reusable APKMirror source plan for ${version}"
				continue
			fi
		else
			declare -F "dl_${source_name}_shared" >/dev/null || continue
			pr "Looking for a shared source payload from '${source_name}'"
			if ! acquisition_source_resp "$source_name" "${args[${source_name}_dlurl]}"; then
				npr "Could not inspect '${source_name}' for shared stock"
				continue
			fi
			payload="$TEMP_DIR/shared-${source_name}.payload"
			rm -f "$payload" "${payload}.source.json" "${payload}.inventory.json"
			if ! REQUEST_FAILURE_LEVEL=notice "dl_${source_name}_shared" "${args[${source_name}_dlurl]}" "$version" "$payload" "$arches_json" "$dpi"; then
				npr "No reusable shared payload from '${source_name}' for ${version}"
				continue
			fi
			if ! prepare_generic_shared_payload "$source_name" "$payload" "$pkg_name" "$version" "$arches_json" "$candidate_out"; then
				rm -f "$payload" "${payload}.source.json" "${payload}.inventory.json"
				continue
			fi
			rm -f "$payload" "${payload}.source.json" "${payload}.inventory.json"
		fi

		jq -e '.status == "ready" and (.coverage.missingRequired | length == 0)' "$candidate_out/source.json" >/dev/null 2>&1 || continue
		candidate_score=$(source_candidate_score "$candidate_out/source.json" "$source_name") || continue
		pr "Shared source candidate '${source_name}' scored ${candidate_score} with $(jq -r '(.availableBuildArches // []) | join(",")' "$candidate_out/source.json")"
		if [ "$candidate_score" -gt "$best_score" ]; then
			best_score=$candidate_score
			best_dir="$candidate_out"
		fi
		# Discovery has already compared provider/version metadata. Once this DAG
		# node materializes every requested capability in one artifact, later
		# payload nodes cannot improve coverage or download count, so do not waste
		# bandwidth merely to compare equivalent transports.
		local candidate_artifacts
		candidate_artifacts=$(jq -r '.downloadPlan.artifactCount // .selection.artifactCount // 1' "$candidate_out/source.json")
		if [ "$candidate_artifacts" -le 1 ] && jq -e '((.coverage.missingRequired // []) + (.coverage.missingDesired // []) + (.coverage.missingOptional // [])) | length == 0' "$candidate_out/source.json" >/dev/null 2>&1; then
			break
		fi
	done

	if [ -n "$best_dir" ]; then
		rm -rf "$out"
		mkdir -p "$out"
		cp -a "$best_dir/." "$out/"
		pr "Selected shared source '$(jq -r .sourceName "$out/source.json")' for '${BUILD_TARGET:-$pkg_name}'"
		return 0
	fi

	jq -n --arg target "${BUILD_TARGET:-}" --arg package "$pkg_name" --arg version "$version" --argjson requestedArches "$arches_json" \
		'{schemaVersion:2,status:"unavailable",shared:false,target:$target,packageName:$package,version:$version,requestedArches:$requestedArches,availableBuildArches:[],coverage:{required:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch]),available:[],missingRequired:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch])},reason:"No configured source exposed a reusable shared candidate"}' \
		>"$out/source.json"
	annotate_source_coverage "$out/source.json" "$arches_json" '[]' || return 1
	pr "No broad source is available; source planning will try branch acquisition"
	return 0
}

materialize_prepared_source_branches() {
	# Convert a partitioned shared container into self-contained per-architecture
	# branch payloads before mixing it with branches acquired from other sources.
	# This is only used for partial broad candidates; fully covered partitions keep
	# their common/ABI de-duplication in the normal workflow path.
	local arches_json=$1 out=${BUILD_SOURCE_OUTPUT_DIR:-} strategy source_name trust provenance_family provenance_domain
	local arch branch_dir available_json tmp_branches
	local available_arches=()
	[ -n "$out" ] && [ -f "$out/source.json" ] || return 1
	strategy=$(jq -r '.strategy // "partition"' "$out/source.json")
	[ "$strategy" = partition ] || return 0
	source_name=$(jq -r '.sourceName // empty' "$out/source.json")
	trust=$(jq -r '.trustClass // empty' "$out/source.json")
	provenance_family=$(jq -r '.sourceProvenanceFamily // empty' "$out/source.json")
	provenance_domain=$(jq -r '.sourceProvenanceDomain // empty' "$out/source.json")
	tmp_branches="$TEMP_DIR/materialized-source-branches"
	rm -rf "$tmp_branches"; mkdir -p "$tmp_branches"
	while IFS= read -r arch; do
		[ -n "$arch" ] || continue
		jq -e --arg arch "$arch" '(.availableBuildArches // []) | index($arch) != null' "$out/source.json" >/dev/null || continue
		branch_dir="$tmp_branches/$arch"
		mkdir -p "$branch_dir/splits"
		materialize_partition_splits "$out" "$arch" "$branch_dir/splits" "$branch_dir/selection.json" || return 1
		jq -n --arg arch "$arch" --arg sourceName "$source_name" --arg trustClass "$trust" \
			--arg provenanceFamily "$provenance_family" --arg provenanceDomain "$provenance_domain" \
			'{schemaVersion:2,available:true,arch:$arch,sourceName:$sourceName,format:"BUNDLE",trustClass:$trustClass,sourceProvenanceFamily:$provenanceFamily,sourceProvenanceDomain:$provenanceDomain,signerVerified:true,derivation:"split-partition"}' \
			>"$branch_dir/branch.json"
		available_arches+=("$arch")
	done < <(jq -r '.[] | if type == "string" then . else .arch end' <<<"$arches_json")
	rm -rf "$out/branches"
	mv "$tmp_branches" "$out/branches"
	available_json=$(printf '%s\n' "${available_arches[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
	jq --argjson available "$available_json" \
		'.strategy="branches" | .materializedFrom="partition" | .availableBuildArches=$available' \
		"$out/source.json" >"$out/source.json.tmp" && mv -f "$out/source.json.tmp" "$out/source.json"
	annotate_source_coverage "$out/source.json" "$arches_json" "$available_json" || return 1
}


branch_source_candidate_score() {
	# Prefer derivable split containers over flattened standalone APKs. Within the
	# same representation choose the smaller validated payload, then use provider
	# rank only as a tie breaker. This prevents an early large standalone from
	# hiding a later compact XAPK/APKM candidate for the same ABI.
	local candidate_dir=$1 source_name=$2 format=$3 bytes mib format_bonus source_bonus
	bytes=$(du -sb "$candidate_dir" 2>/dev/null | awk '{print $1}' || echo 0)
	[[ $bytes =~ ^[0-9]+$ ]] || bytes=0
	mib=$((bytes / 1048576))
	case "$format" in
	BUNDLE) format_bonus=1000000 ;;
	*) format_bonus=0 ;;
	esac
	case "$source_name" in
	direct) source_bonus=60 ;;
	apkmirror) source_bonus=50 ;;
	apkfab) source_bonus=45 ;;
	apkpure) source_bonus=40 ;;
	archive) source_bonus=30 ;;
	uptodown) source_bonus=20 ;;
	aptoide) source_bonus=10 ;;
	*) source_bonus=0 ;;
	esac
	echo $((format_bonus - mib * 100 + source_bonus))
}

prepare_branch_stock_sources() {
	local pkg_name=$1 version=$2 dpi=$3 arches_json=$4 graph=${5:-} preserve=${6:-false} out=${BUILD_SOURCE_OUTPUT_DIR:-}
	local arch optional source_priority source_name stock branch_dir sig_op format source_names=() available_arches=()
	local required_missing=false found=false reason trust provenance_family provenance_domain
	local branch_source_order=() candidate_root candidate_dir candidate_score best_score best_dir best_source selection_error rejection_category
	[ -n "$out" ] || { epr "BUILD_SOURCE_OUTPUT_DIR is required for source-only builds"; return 1; }
	if [ "$preserve" != true ]; then rm -rf "$out"; fi
	mkdir -p "$out/branches"

	while IFS=$'\t' read -r arch optional source_priority; do
		[ -n "$arch" ] || continue
		branch_dir="$out/branches/$arch"
		mkdir -p "$branch_dir"
		if [ "$preserve" = true ] && [ -f "$branch_dir/branch.json" ] && jq -e '.available == true' "$branch_dir/branch.json" >/dev/null 2>&1; then
			source_name=$(jq -r '.sourceName // empty' "$branch_dir/branch.json")
			[ -z "$source_name" ] || source_names+=("$source_name")
			available_arches+=("$arch")
			continue
		fi
		found=false
		reason="No configured stock source could acquire ${arch} for ${pkg_name} ${version}"
		if [ -n "$graph" ] && [ -f "$graph" ]; then
			mapfile -t branch_source_order < <(source_graph_sources "$graph" "$version" branch)
		else
			branch_source_order=("${DL_SRCS[@]}")
		fi
		candidate_root="$TEMP_DIR/source-branch-candidates-${arch//[^A-Za-z0-9_.-]/_}"
		rm -rf "$candidate_root"; mkdir -p "$candidate_root"
		best_score=-999999999
		best_dir=""
		best_source=""
		for source_name in "${branch_source_order[@]}"; do
			[ -n "${args[${source_name}_dlurl]-}" ] || continue
			declare -F "dl_${source_name}" >/dev/null || continue
			pr "Traversing '$arch' source DAG node '${source_name}'"
			if ! acquisition_source_resp "$source_name" "${args[${source_name}_dlurl]}"; then
				npr "Could not inspect '${source_name}' for '$arch' DAG acquisition"
				continue
			fi
			stock="$TEMP_DIR/source-branch-${arch}-${source_name}.apk"
			rm -f "$stock" "${stock}.bundle" "${stock}.bundle-selection.json"
			if ! REQUEST_FAILURE_LEVEL=notice "dl_${source_name}" "${args[${source_name}_dlurl]}" "$version" "$stock" "$arch" "$dpi" false; then
				npr "DAG payload node '${source_name}' failed: version='$version' arch='$arch'"
				continue
			fi
			candidate_dir="$candidate_root/$source_name"
			rm -rf "$candidate_dir"; mkdir -p "$candidate_dir"
			if [ -f "${stock}.bundle" ]; then
				mkdir -p "$candidate_dir/splits"
				if source_payload_was_rejected "$source_name" "$version" "$arch" "${stock}.bundle"; then
					npr "Skipping repeated rejected '$source_name' payload for version='$version' arch='$arch'"
					rm -rf "$candidate_dir"
					continue
				fi
				selection_error=""
				if ! selection_error=$(select_bundle_splits "${stock}.bundle" "$arch" "$candidate_dir/splits" "$candidate_dir/selection.json" 2>&1); then
					[ -z "$selection_error" ] || printf '%s\n' "$selection_error" >&2
					rejection_category=split-selection-failed
					[[ $selection_error == *"bundle can derive"* ]] && rejection_category=wrong-abi
					record_source_payload_rejection "$source_name" "$version" "$arch" "${stock}.bundle" "$rejection_category" "${selection_error//$'\n'/ }"
					rm -rf "$candidate_dir"
					continue
				fi
				while IFS= read -r -d '' split_apk; do
					if ! sig_op=$(check_sig "$split_apk" "$pkg_name" "$source_name" 2>&1); then
						epr "Fallback source signature mismatch '$split_apk': $sig_op"
						rm -rf "$candidate_dir"
						continue 2
					fi
				done < <(find "$candidate_dir/splits" -type f -name '*.apk' -print0)
				format=BUNDLE
			else
				if ! validate_optional_auto_abi "$stock" "$arch" false; then
					npr "DAG node '${source_name}' standalone APK cannot derive a distinct '$arch' artifact"
					rm -rf "$candidate_dir"
					continue
				fi
				if ! sig_op=$(check_sig "$stock" "$pkg_name" "$source_name" 2>&1); then
					epr "Fallback source signature mismatch '$stock': $sig_op"
					rm -rf "$candidate_dir"
					continue
				fi
				cp -f "$stock" "$candidate_dir/stock.apk"
				format=APK
			fi
			trust=$(source_trust_class "$source_name")
			provenance_family=$(source_provenance_family "$source_name")
			provenance_domain=$(source_provenance_domain "$source_name" "${args[${source_name}_dlurl]-}")
			jq -n \
				--arg arch "$arch" --arg sourceName "$source_name" --arg format "$format" \
				--arg trustClass "$trust" --arg provenanceFamily "$provenance_family" --arg provenanceDomain "$provenance_domain" \
				'{schemaVersion:2,available:true,arch:$arch,sourceName:$sourceName,format:$format,trustClass:$trustClass,sourceProvenanceFamily:$provenanceFamily,sourceProvenanceDomain:$provenanceDomain,signerVerified:true}' \
				>"$candidate_dir/branch.json"
			candidate_score=$(branch_source_candidate_score "$candidate_dir" "$source_name" "$format") || continue
			pr "Branch source candidate '${source_name}' for '$arch' scored ${candidate_score} as ${format} ($(du -sh "$candidate_dir" | awk '{print $1}'))"
			if [ "$candidate_score" -gt "$best_score" ]; then
				best_score=$candidate_score
				best_dir="$candidate_dir"
				best_source="$source_name"
			fi
			rm -f "$stock" "${stock}.bundle" "${stock}.bundle-selection.json"
		done
		rm -f "$TEMP_DIR/source-branch-${arch}-"*.apk "$TEMP_DIR/source-branch-${arch}-"*.apk.bundle "$TEMP_DIR/source-branch-${arch}-"*.apk.bundle-selection.json 2>/dev/null || :
		if [ -n "$best_dir" ] && [ -d "$best_dir" ]; then
			rm -rf "$branch_dir"; mkdir -p "$branch_dir"
			cp -a "$best_dir/." "$branch_dir/"
			source_names+=("$best_source")
			available_arches+=("$arch")
			found=true
			pr "Selected branch source '${best_source}' for '$arch'"
		fi
		rm -rf "$candidate_root"
		if [ "$found" != true ]; then
			jq -n --arg arch "$arch" --arg reason "$reason" --argjson optional "$optional" \
				'{schemaVersion:1,available:false,arch:$arch,optional:$optional,reason:$reason}' >"$branch_dir/branch.json"
			if [ "$source_priority" = required ]; then required_missing=true; fi
		fi
	done < <(jq -r '.[] | if type == "string" then [.,false,"required"] else [.arch,(.optional // false),(.sourcePriority // (if (.optional // false) then "desired" else "required" end))] end | @tsv' <<<"$arches_json")

	local unique_sources source_summary available_json sources_json plan_ready=false
	unique_sources=$(printf '%s\n' "${source_names[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -)
	if [[ "$unique_sources" == *,* ]]; then source_summary=mixed; else source_summary=${unique_sources:-none}; fi
	available_json=$(printf '%s\n' "${available_arches[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
	sources_json=$(printf '%s\n' "${source_names[@]}" | awk 'NF && !seen[$0]++' | jq -Rsc 'split("\n") | map(select(length > 0))')
	if [ "$required_missing" != true ] && jq -e 'length > 0' <<<"$available_json" >/dev/null; then
		plan_ready=true
	fi
	jq -n \
		--arg target "${BUILD_TARGET:-}" --arg package "$pkg_name" --arg version "$version" \
		--arg sourceName "$source_summary" --argjson sources "$sources_json" --argjson requestedArches "$arches_json" --argjson availableBuildArches "$available_json" \
		--argjson shared "$plan_ready" --argjson hybrid "$([ "$preserve" = true ] && echo true || echo false)" \
		'{schemaVersion:2,status:(if $shared then "ready" else "unavailable" end),shared:$shared,strategy:"branches",hybrid:$hybrid,target:$target,packageName:$package,version:$version,sourceName:$sourceName,sources:$sources,requestedArches:$requestedArches,availableBuildArches:$availableBuildArches,coverage:{required:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch]),available:$availableBuildArches,missingRequired:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch] - $availableBuildArches)}}' \
		>"$out/source.json"
	annotate_source_coverage "$out/source.json" "$arches_json" "$available_json" || return 1
	[ "$plan_ready" = true ]
}


source_verification_summary() {
	local security_file=$1 arch=$2
	jq -c --arg arch "$arch" '{
		arch:$arch,
		securityValidated:(.securityValidated == true),
		comparisonSha256:(.comparisonSha256 // ""),
		crossSource:(.crossSource // {status:"unavailable"})
	}' "$security_file"
}

verify_prepared_source_acquisition() {
	local pkg_name=$1 version=$2 dpi=$3 out=${BUILD_SOURCE_OUTPUT_DIR:-}
	local strategy arch source_name branch_dir stock security rc summary
	[ -n "$out" ] && [ -f "$out/source.json" ] || return 1
	jq -e '.status == "ready" and ((.availableBuildArches // []) | length > 0)' "$out/source.json" >/dev/null 2>&1 || return 1
	strategy=$(jq -r '.strategy // "partition"' "$out/source.json")

	if [ "$strategy" = branches ]; then
		while IFS= read -r arch; do
			[ -n "$arch" ] || continue
			branch_dir="$out/branches/$arch"
			[ -f "$branch_dir/branch.json" ] || continue
			jq -e '.available == true' "$branch_dir/branch.json" >/dev/null 2>&1 || continue
			source_name=$(jq -r '.sourceName // empty' "$branch_dir/branch.json")
			[ -n "$source_name" ] || { epr "Prepared '$arch' branch has no source identity"; return 1; }
			stock="$TEMP_DIR/source-verify-${arch}.apk"
			security="$branch_dir/source.security.json"
			rm -f "$stock" "$security"
			if [ -f "$branch_dir/stock.apk" ]; then
				cp -f "$branch_dir/stock.apk" "$stock"
			elif [ -d "$branch_dir/splits" ]; then
				merge_split_dir_unsigned "$branch_dir/splits" "$stock" || return 1
			else
				epr "Prepared '$arch' branch has no verifiable payload"
				return 1
			fi
			verify_stock_security "$stock" "$pkg_name" "$version" "$source_name" "$security" || return 1
			local branch_format
			branch_format=$(jq -r '.format // "APK"' "$branch_dir/branch.json")
			rc=0
			corroborate_stock_source "$source_name" "$stock" "$security" "$pkg_name" "$version" "$arch" "$dpi" false "$branch_format" || rc=$?
			rm -f "$stock" "${stock}.bundle" "${stock}.bundle-selection.json"
			if [ "$rc" -eq 20 ]; then return 20; fi
			[ "$rc" -eq 0 ] || return "$rc"
			summary=$(source_verification_summary "$security" "$arch") || return 1
			jq --argjson verification "$summary" '.verification=$verification' "$branch_dir/branch.json" >"$branch_dir/branch.json.tmp" &&
				mv -f "$branch_dir/branch.json.tmp" "$branch_dir/branch.json"
		done < <(jq -r '.availableBuildArches[]?' "$out/source.json")
		jq '.verification={status:"complete",scope:"per-branch"}' "$out/source.json" >"$out/source.json.tmp" &&
			mv -f "$out/source.json.tmp" "$out/source.json"
		return 0
	fi

	# One representative install set is enough for a partitioned source because
	# every raw split in the shared container has already passed the upstream
	# signer gate. Prefer a concrete ARM branch to avoid comparing a synthetic
	# multi-ABI universal merge when an independent store only exposes one ABI.
	arch=$(jq -r '
		(.availableBuildArches // []) as $a |
		(["arm64-v8a","arm-v7a","x86_64","x86","universal"] | map(select(. as $x | $a | index($x) != null)) | .[0]) // empty
	' "$out/source.json")
	[ -n "$arch" ] || { epr "Prepared shared source exposes no materializable architecture"; return 1; }
	source_name=$(jq -r '.sourceName // empty' "$out/source.json")
	[ -n "$source_name" ] || return 1
	stock="$TEMP_DIR/source-verify-${arch}.apk"
	security="$out/source.security.json"
	rm -f "$stock" "$security"
	merge_partitioned_stock "$out" "$stock" "$arch" || return 1
	verify_stock_security "$stock" "$pkg_name" "$version" "$source_name" "$security" || return 1
	rc=0
	corroborate_stock_source "$source_name" "$stock" "$security" "$pkg_name" "$version" "$arch" "$dpi" false BUNDLE || rc=$?
	rm -f "$stock" "${stock}.bundle" "${stock}.bundle-selection.json"
	if [ -n "${SHARED_SOURCE_SELECTED_SPLITS_DIR:-}" ]; then
		rm -rf "$SHARED_SOURCE_SELECTED_SPLITS_DIR"
		SHARED_SOURCE_SELECTED_SPLITS_DIR=""
	fi
	if [ "$rc" -eq 20 ]; then return 20; fi
	[ "$rc" -eq 0 ] || return "$rc"
	summary=$(source_verification_summary "$security" "$arch") || return 1
	jq --argjson verification "$summary" '.verification=$verification' "$out/source.json" >"$out/source.json.tmp" &&
		mv -f "$out/source.json.tmp" "$out/source.json"
}

inherit_prepared_source_verification() {
	local security_file=$1 source_root=${BUILD_STOCK_SOURCE_DIR:-} strategy verification status source digest family domain
	[ -n "$source_root" ] && [ -f "$source_root/source.json" ] || return 1
	strategy=$(jq -r '.strategy // "partition"' "$source_root/source.json")
	if [ "$strategy" = branches ]; then
		[ -f "$source_root/branch/branch.json" ] || return 1
		verification=$(jq -c '.verification // empty' "$source_root/branch/branch.json")
	else
		verification=$(jq -c '.verification // empty' "$source_root/source.json")
	fi
	[ -n "$verification" ] || return 1
	status=$(jq -r '.crossSource.status // empty' <<<"$verification")
	[ -n "$status" ] || return 1
	source=$(jq -r '.crossSource.source // empty' <<<"$verification")
	digest=$(jq -r '.crossSource.comparisonSha256 // empty' <<<"$verification")
	family=$(jq -r '.crossSource.provenanceFamily // empty' <<<"$verification")
	domain=$(jq -r '.crossSource.provenanceDomain // empty' <<<"$verification")
	annotate_cross_source_verification "$security_file" "$status" "$source" "$digest" "$family" "$domain"
}

source_discovery_provider() {
	local source_name=$1 locator=$2 output=$3 versions status=unavailable version_opaque=false
	(
		set +e
		__AAV__=true
		if declare -F "get_${source_name}_resp" >/dev/null && REQUEST_FAILURE_LEVEL=notice "get_${source_name}_resp" "$locator"; then
			status=ready
			versions=$("get_${source_name}_vers" 2>/dev/null || :)
		else
			versions=""
		fi
		local versions_json
		versions_json=$(printf '%s\n' "$versions" | awk 'NF' | jq -Rsc 'split("\n") | map(select(length > 0) | sub("^v"; "")) | unique')
		if [ "$status" = ready ] && [ "$(jq 'length' <<<"$versions_json")" -eq 0 ]; then
			version_opaque=true
		fi
		jq -n \
			--arg source "$source_name" \
			--arg status "$status" \
			--arg provenanceFamily "$(source_provenance_family "$source_name")" \
			--arg provenanceDomain "$(source_provenance_domain "$source_name" "$locator")" \
			--argjson versions "$versions_json" \
			--argjson versionOpaque "$version_opaque" \
			'{schemaVersion:1,source:$source,configured:true,status:$status,versions:$versions,versionOpaque:$versionOpaque,provenanceFamily:$provenanceFamily,provenanceDomain:$provenanceDomain}' \
			>"$output"
	) || {
		jq -n --arg source "$source_name" '{schemaVersion:1,source:$source,configured:true,status:"unavailable",versions:[],versionOpaque:false}' >"$output"
	}
}

# Discover every configured provider before downloading stock payloads. The
# resulting graph is the source policy: provider arrays are merely discovery
# adapters and never act as an implicit first-success fallback order.
discover_stock_source_graph() {
	local pkg_name=$1 arches_json=$2 versions_json=$3 output=$4 forward_probe_limit=${5:-0}
	local discovery_dir="$TEMP_DIR/source-discovery" source_name locator pid failed=0
	local pids=()
	rm -rf "$discovery_dir"; mkdir -p "$discovery_dir"
	for source_name in "${SOURCE_ADAPTERS[@]}"; do
		locator=${args[${source_name}_dlurl]-}
		[ -n "$locator" ] || continue
		source_discovery_provider "$source_name" "$locator" "$discovery_dir/${source_name}.json" &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
	# Discovery is best effort by provider; an individual metadata endpoint may
	# fail while its exact-version payload path still works, so unavailable
	# providers remain explicit probe nodes in the graph.
	[ "$failed" -eq 0 ] || npr "One or more source metadata probes failed; keeping them as explicit DAG probe nodes"
	if ! compgen -G "$discovery_dir/*.json" >/dev/null; then
		epr "No configured stock source providers exist"
		return 1
	fi
	jq -s '.' "$discovery_dir"/*.json >"$discovery_dir/observations.json" || return 1
	python3 "$CWD/scripts/source_graph.py" \
		--observations "$discovery_dir/observations.json" \
		--versions-json "$versions_json" \
		--arches-json "$arches_json" \
		--forward-probe-limit "$forward_probe_limit" \
		--output "$output" >/dev/null || return 1
	jq -e '.kind == "source-acquisition-dag" and (.providers | length) > 0 and (.versionTraversal | length) > 0' "$output" >/dev/null || return 1
}


discover_stock_source_candidates() {
	local pkg_name=$1 arches_json=$2 versions_json=$3 forward_probe_limit=${4:-0} out=${BUILD_SOURCE_OUTPUT_DIR:-}
	local graph
	[ -n "$out" ] || { epr "BUILD_SOURCE_OUTPUT_DIR is required for source discovery"; return 1; }
	if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null <<<"$versions_json"; then
		epr "BUILD_SOURCE_VERSIONS_JSON must contain concrete version candidates"
		return 1
	fi
	rm -rf "$out"; mkdir -p "$out"
	graph="$out/source-graph.json"
	pr "Discovering source DAG candidates without downloading stock payloads"
	discover_stock_source_graph "$pkg_name" "$arches_json" "$versions_json" "$graph" "$forward_probe_limit" || return 1
	jq '{schemaVersion:1,status:"ready",declaredVersions,forwardProbeVersions,candidateVersions,versionTraversal,providers}' "$graph" >"$out/source-discovery.json" || return 1
	pr "Source DAG candidates: $(jq -r '.versionTraversal | join(" -> ")' "$graph")"
}

source_graph_sources() {
	local graph=$1 version=$2 kind=$3
	[ -f "$graph" ] || return 1
	case "$kind" in
	broad) jq -r --arg version "${version#v}" '.versions[] | select(.version == $version) | .broadSources[]?' "$graph" ;;
	branch) jq -r --arg version "${version#v}" '.versions[] | select(.version == $version) | .branchSources[]?' "$graph" ;;
	*) return 1 ;;
	esac
}

prepare_stock_source_candidates() {
	local pkg_name=$1 dpi=$2 arches_json=$3 versions_json=$4 out=${BUILD_SOURCE_OUTPUT_DIR:-}
	local version first_version="" first_meta="$TEMP_DIR/first-source-unavailable.json"
	local graph="$TEMP_DIR/source-acquisition-graph.json"
	if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null <<<"$versions_json"; then
		epr "BUILD_SOURCE_VERSIONS_JSON must contain concrete version candidates"
		return 1
	fi
	rm -f "$first_meta" "$graph"
	if [ -n "${BUILD_SOURCE_GRAPH_FILE:-}" ] && [ -s "$BUILD_SOURCE_GRAPH_FILE" ]; then
		cp -f "$BUILD_SOURCE_GRAPH_FILE" "$graph" || return 1
		pr "Using precomputed source discovery DAG for payload acquisition"
	else
		pr "Discovering stock metadata from every configured provider before acquisition"
		discover_stock_source_graph "$pkg_name" "$arches_json" "$versions_json" "$graph" || return 1
	fi
	SOURCE_ACQUISITION_GRAPH=$graph
	export SOURCE_ACQUISITION_GRAPH
	pr "Source DAG version traversal: $(jq -r '.versionTraversal | join(" -> ")' "$graph")"
	while IFS= read -r version; do
		[ -n "$first_version" ] || first_version=$version
		pr "Traversing source DAG for candidate version '$version'"
		prepare_shared_stock_source "$pkg_name" "$version" "$dpi" "$arches_json" "$graph" || continue
		if jq -e '.status == "ready" and .shared == true' "$out/source.json" >/dev/null 2>&1; then
			if jq -e '((.coverage.missingDesired // []) + (.coverage.missingOptional // [])) | length > 0' "$out/source.json" >/dev/null 2>&1; then
				pr "Broad source for '$version' is partial; continuing the DAG for missing architecture branches"
				if materialize_prepared_source_branches "$arches_json" && \
					prepare_branch_stock_sources "$pkg_name" "$version" "$dpi" "$arches_json" "$graph" true && \
					verify_prepared_source_acquisition "$pkg_name" "$version" "$dpi"; then
					cp -f "$graph" "$out/source-graph.json"
					return 0
				fi
				npr "Hybrid broad/branch source plan for '$version' failed acquisition-time verification"
			else
				if verify_prepared_source_acquisition "$pkg_name" "$version" "$dpi"; then
					cp -f "$graph" "$out/source-graph.json"
					return 0
				fi
				npr "Broad source for '$version' failed acquisition-time provenance verification"
			fi
		fi
		npr "No verified broad DAG node covered '$version'; traversing architecture acquisition nodes"
		if prepare_branch_stock_sources "$pkg_name" "$version" "$dpi" "$arches_json" "$graph" &&
			verify_prepared_source_acquisition "$pkg_name" "$version" "$dpi"; then
			cp -f "$graph" "$out/source-graph.json"
			return 0
		fi
		[ -f "$first_meta" ] || cp -f "$out/source.json" "$first_meta"
		npr "Candidate '$version' has no complete source-stage acquisition path; following the next version node"
	done < <(jq -r --argjson requested "$versions_json" '.versionTraversal[] | select(. as $version | $requested | index($version) != null)' "$graph")
	# Required variants never fall back to network access in architecture jobs.
	# Stop at the source boundary instead of multiplying the same acquisition
	# failure across every ABI and patch mode.
	if [ -f "$first_meta" ]; then
		rm -rf "$out"; mkdir -p "$out"
		cp -f "$first_meta" "$out/source.json"
		cp -f "$graph" "$out/source-graph.json"
		epr "No source DAG path produced a complete acquisition plan for '$first_version'"
	fi
	return 1
}

try_shared_stock_source() {
	local stock_apk=$1 arch=$2 source=${BUILD_STOCK_SOURCE_DIR:-} strategy branch
	[ -n "$source" ] || return 10
	[ -f "$source/source.json" ] || return 10
	jq -e '.shared == true' "$source/source.json" >/dev/null || return 10
	strategy=$(jq -r '.strategy // "partition"' "$source/source.json")
	CURRENT_STOCK_SOURCE=$(jq -r '.sourceName // .selection.source // "shared"' "$source/source.json")
	CURRENT_STOCK_TRUST_CLASS=$(source_trust_class "$CURRENT_STOCK_SOURCE")
	if [ "$strategy" = branches ]; then
		branch="$source/branch"
		[ -f "$branch/branch.json" ] || return 10
		if jq -e '.available == false' "$branch/branch.json" >/dev/null 2>&1; then
			SHARED_SOURCE_UNAVAILABLE_REASON=$(jq -r '.reason // "source branch unavailable"' "$branch/branch.json")
			return 11
		fi
		CURRENT_STOCK_SOURCE=$(jq -r '.sourceName // empty' "$branch/branch.json")
		[ -n "$CURRENT_STOCK_SOURCE" ] || CURRENT_STOCK_SOURCE=$(jq -r '.sourceName // .selection.source // "shared"' "$source/source.json")
		CURRENT_STOCK_TRUST_CLASS=$(source_trust_class "$CURRENT_STOCK_SOURCE")
		if [ -f "$branch/stock.apk" ]; then
			cp -f "$branch/stock.apk" "$stock_apk"
			PREPARED_STOCK_VERIFIED=true
			return 0
		fi
		[ -d "$branch/splits" ] || return 10
		SHARED_SOURCE_SELECTED_SPLITS_DIR="$branch/splits"
		if ! merge_split_dir_unsigned "$branch/splits" "$stock_apk"; then
			SHARED_SOURCE_SELECTED_SPLITS_DIR=""
			return 10
		fi
		[ ! -f "$branch/selection.json" ] || cp -f "$branch/selection.json" "${stock_apk}.bundle-selection.json"
		PREPARED_STOCK_VERIFIED=true
		return 0
	fi
	if ! merge_partitioned_stock "$source" "$stock_apk" "$arch"; then
		npr "Prepared source cannot produce '$arch'"
		SHARED_SOURCE_SELECTED_SPLITS_DIR=""
		return 10
	fi
	PREPARED_STOCK_VERIFIED=true
	return 0
}

export_stock_result() {
	local stock_apk=$1 pkg_name=$2 version=$3 arch=$4 include_stock=${5:-merged} out=${BUILD_STOCK_OUTPUT_DIR:-}
	local digest split_container=false source_name=${CURRENT_STOCK_SOURCE:-unknown} trust_class fingerprint_sha="" cross_status="" cross_source=""
	local provenance_family="" provenance_domain="" cross_family="" cross_domain=""
	trust_class=$(source_trust_class "$source_name")
	[ -n "$out" ] || { epr "BUILD_STOCK_OUTPUT_DIR is required for stock-only builds"; return 1; }
	mkdir -p "$out"
	cp -f "$stock_apk" "$out/stock.apk"
	digest=$(sha256sum "$stock_apk" | awk '{print toupper($1)}')
	if [ -n "${SHARED_SOURCE_SELECTED_SPLITS_DIR:-}" ] && [ -d "$SHARED_SOURCE_SELECTED_SPLITS_DIR" ]; then
		split_container=true
		if [ "$include_stock" = split ]; then
			mkdir -p "$out/stock-splits"
			cp -f "$SHARED_SOURCE_SELECTED_SPLITS_DIR"/*.apk "$out/stock-splits/"
		fi
	elif [ -f "${stock_apk}.bundle" ]; then
		split_container=true
		# Keep only the selected install set when a module explicitly embeds stock
		# splits. The original multi-ABI container is intentionally not handed to
		# patch jobs: it is large and its upstream signatures were verified here.
		if [ "$include_stock" = split ]; then
			select_bundle_splits "${stock_apk}.bundle" "$arch" "$out/stock-splits" || return 1
		fi
	fi
	if [ -f "${stock_apk}.bundle-selection.json" ]; then
		cp -f "${stock_apk}.bundle-selection.json" "$out/stock.bundle-selection.json"
	fi
	[ -f "${stock_apk}.security.json" ] || { epr "Refusing to export stock without a security fingerprint"; return 1; }
	cp -f "${stock_apk}.security.json" "$out/stock.security.json"
	fingerprint_sha=$(jq -r '.comparisonSha256 // empty' "${stock_apk}.security.json")
	cross_status=$(jq -r '.crossSource.status // empty' "${stock_apk}.security.json")
	cross_source=$(jq -r '.crossSource.source // empty' "${stock_apk}.security.json")
	provenance_family=$(jq -r '.sourceProvenanceFamily // empty' "${stock_apk}.security.json")
	provenance_domain=$(jq -r '.sourceProvenanceDomain // empty' "${stock_apk}.security.json")
	cross_family=$(jq -r '.crossSource.provenanceFamily // empty' "${stock_apk}.security.json")
	cross_domain=$(jq -r '.crossSource.provenanceDomain // empty' "${stock_apk}.security.json")
	[ -n "$provenance_family" ] || provenance_family=$(source_provenance_family "$source_name")
	[ -n "$provenance_domain" ] || provenance_domain=$(source_provenance_domain "$source_name" "$(configured_source_locator "$source_name")")
	[ -n "$fingerprint_sha" ] || { epr "Stock security fingerprint has no comparison digest"; return 1; }
	jq -n \
		--arg target "${BUILD_TARGET:-}" \
		--arg package "$pkg_name" \
		--arg version "$version" \
		--arg arch "$arch" \
		--arg sha256 "$digest" \
		--arg sourceName "$source_name" \
		--arg trustClass "$trust_class" \
		--arg provenanceFamily "$provenance_family" \
		--arg provenanceDomain "$provenance_domain" \
		--arg fingerprintSha256 "$fingerprint_sha" \
		--arg crossSourceStatus "$cross_status" \
		--arg crossSource "$cross_source" \
		--arg crossSourceProvenanceFamily "$cross_family" \
		--arg crossSourceProvenanceDomain "$cross_domain" \
		--argjson splitContainer "$split_container" \
		'{schemaVersion:1,target:$target,packageName:$package,version:$version,arch:$arch,sha256:$sha256,sourceName:$sourceName,trustClass:$trustClass,sourceProvenanceFamily:$provenanceFamily,sourceProvenanceDomain:$provenanceDomain,signerPinRequired:($sourceName != "direct"),fingerprintSha256:$fingerprintSha256,crossSourceStatus:$crossSourceStatus,crossSource:$crossSource,crossSourceProvenanceFamily:$crossSourceProvenanceFamily,crossSourceProvenanceDomain:$crossSourceProvenanceDomain,splitContainer:$splitContainer,stockValidated:true,securityValidated:($fingerprintSha256 != "")}' \
		>"$out/stock.json"
}

import_stock_result() {
	local stock_apk=$1 source=${BUILD_STOCK_DIR:-} reason expected actual
	[ -n "$source" ] || return 1
	if [ -f "$source/skip.json" ]; then
		reason=$(jq -r '.reason // "stock variant unavailable"' "$source/skip.json")
		record_optional_variant_skip "$reason" || return 2
		return 10
	fi
	[ -f "$source/stock.apk" ] || { epr "Prepared stock artifact is missing '$source/stock.apk'"; return 2; }
	[ -f "$source/stock.json" ] || { epr "Prepared stock artifact is missing verification metadata"; return 2; }
	expected=$(jq -r '.sha256 // empty' "$source/stock.json")
	[ -n "$expected" ] || { epr "Prepared stock artifact has no SHA-256"; return 2; }
	actual=$(sha256sum "$source/stock.apk" | awk '{print toupper($1)}')
	[ "${expected^^}" = "$actual" ] || { epr "Prepared stock artifact SHA-256 mismatch"; return 2; }
	jq -e '.stockValidated == true and .securityValidated == true and (.sourceName | type == "string" and length > 0)' "$source/stock.json" >/dev/null || { epr "Prepared stock artifact was not fully validated by the stock stage"; return 2; }
	[ -f "$source/stock.security.json" ] || { epr "Prepared stock artifact is missing its security fingerprint"; return 2; }
	local fingerprint_expected fingerprint_actual fingerprint_artifact
	fingerprint_expected=$(jq -r '.fingerprintSha256 // empty' "$source/stock.json")
	fingerprint_actual=$(jq -r '.comparisonSha256 // empty' "$source/stock.security.json")
	fingerprint_artifact=$(jq -r '.artifactSha256 // empty' "$source/stock.security.json")
	[ -n "$fingerprint_expected" ] && [ "${fingerprint_expected^^}" = "${fingerprint_actual^^}" ] || { epr "Prepared stock security fingerprint mismatch"; return 2; }
	[ "${fingerprint_artifact^^}" = "$actual" ] || { epr "Prepared stock security fingerprint does not describe stock.apk"; return 2; }
	CURRENT_STOCK_SOURCE=$(jq -r '.sourceName' "$source/stock.json")
	CURRENT_STOCK_TRUST_CLASS=$(jq -r '.trustClass // "unknown"' "$source/stock.json")
	cp -f "$source/stock.apk" "$stock_apk"
	cp -f "$source/stock.security.json" "${stock_apk}.security.json"
	[ ! -f "$source/stock.bundle-selection.json" ] || cp -f "$source/stock.bundle-selection.json" "${stock_apk}.bundle-selection.json"
	PREPARED_STOCK_VERIFIED=true
	PREPARED_STOCK_SPLITS_DIR=""
	[ ! -d "$source/stock-splits" ] || PREPARED_STOCK_SPLITS_DIR="$source/stock-splits"
	return 0
}


export_patch_result() {
	local patched_apk=$1 pkg_name=$2 version=$3 arch=$4 mode=$5 patches_source=$6 patches_version=$7 auxiliary_notice_source=${8:-}
	local out=${BUILD_PATCH_OUTPUT_DIR:-} digest patch_profile_hash=${BUILD_PATCH_PROFILE_HASH:-}
	[ -n "$out" ] || { epr "BUILD_PATCH_OUTPUT_DIR is required for patch-only builds"; return 1; }
	[ -s "$patched_apk" ] || { epr "Patched APK is missing: $patched_apk"; return 1; }
	rm -rf "$out"
	mkdir -p "$out"
	cp -f "$patched_apk" "$out/patched.apk"
	digest=$(sha256sum "$out/patched.apk" | awk '{print toupper($1)}') || return 1
	jq -n \
		--arg target "${BUILD_TARGET:-}" \
		--arg packageName "$pkg_name" \
		--arg version "$version" \
		--arg arch "$arch" \
		--arg mode "$mode" \
		--arg sha256 "$digest" \
		--arg patchesSource "$patches_source" \
		--arg patchesVersion "$patches_version" \
		--arg auxiliaryNoticeSource "$auxiliary_notice_source" \
		--arg patchProfileHash "$patch_profile_hash" \
		'{schemaVersion:1,target:$target,packageName:$packageName,version:$version,arch:$arch,mode:$mode,sha256:$sha256,patchesSource:$patchesSource,patchesVersion:$patchesVersion,auxiliaryNoticeSource:$auxiliaryNoticeSource,patchProfileHash:$patchProfileHash}' \
		>"$out/patch.json"
}

import_patch_result() {
	local output=$1 pkg_name=$2 version=$3 arch=$4 mode=$5 expected_patches_source=${6:-} dir=${BUILD_PATCH_DIR:-} expected actual
	[ -n "$dir" ] || return 10
	[ -s "$dir/patched.apk" ] && [ -s "$dir/patch.json" ] || {
		epr "Prepared patch artifact is incomplete: $dir"
		return 2
	}
	if ! jq -e \
		--arg target "${BUILD_TARGET:-}" \
		--arg packageName "$pkg_name" \
		--arg version "$version" \
		--arg arch "$arch" \
		--arg mode "$mode" \
		--arg patchesSource "$expected_patches_source" \
		--arg patchProfileHash "${BUILD_PATCH_PROFILE_HASH:-}" \
		'(.target // "") == $target and .packageName == $packageName and .version == $version and .arch == $arch and .mode == $mode and ($patchesSource == "" or .patchesSource == $patchesSource) and ($patchProfileHash == "" or .patchProfileHash == $patchProfileHash)' \
		"$dir/patch.json" >/dev/null; then
		epr "Prepared patch metadata does not match ${BUILD_TARGET:-$pkg_name} $version $arch $mode"
		return 2
	fi
	expected=$(jq -r '.sha256 // empty' "$dir/patch.json")
	actual=$(sha256sum "$dir/patched.apk" | awk '{print toupper($1)}') || return 2
	if [ -z "$expected" ] || [ "${expected^^}" != "${actual^^}" ]; then
		epr "Prepared patch artifact SHA-256 mismatch"
		return 2
	fi
	IMPORTED_PATCHES_VERSION=$(jq -r '.patchesVersion // empty' "$dir/patch.json")
	IMPORTED_PATCH_AUXILIARY_NOTICE_SOURCE=$(jq -r '.auxiliaryNoticeSource // empty' "$dir/patch.json")
	cp -f "$dir/patched.apk" "$output"
}

android_abi_for_build_arch() {
	case "$1" in
	arm64-v8a) echo arm64-v8a ;;
	arm-v7a) echo armeabi-v7a ;;
	x86) echo x86 ;;
	x86_64) echo x86_64 ;;
	*) return 1 ;;
	esac
}

stock_native_abis() {
	local apk=$1
	python3 - "$apk" <<'PY_ABIS'
import sys, zipfile
abis = {"arm64-v8a", "armeabi-v7a", "x86", "x86_64"}
try:
    with zipfile.ZipFile(sys.argv[1]) as apk:
        found = {
            parts[1]
            for name in apk.namelist()
            for parts in [name.split("/", 2)]
            if len(parts) >= 3 and parts[0] == "lib" and parts[1] in abis
        }
except (OSError, zipfile.BadZipFile) as exc:
    print(f"Could not inspect stock APK native libraries: {exc}", file=sys.stderr)
    raise SystemExit(2)
for abi in ("arm64-v8a", "armeabi-v7a", "x86_64", "x86"):
    if abi in found:
        print(abi)
PY_ABIS
}

standalone_apk_build_arches() {
	# A standalone APK has already lost the split-container boundaries needed to
	# derive a clean ABI-specific artifact.  Treat runtime compatibility and
	# derivability as separate concepts:
	#   no native libs -> universal only
	#   exactly one ABI -> that ABI only
	#   multiple ABIs -> universal only
	local apk=$1 native_abis count abi
	native_abis=$(stock_native_abis "$apk") || return 1
	count=$(grep -c . <<<"$native_abis" || :)
	if [ "$count" -eq 0 ] || [ "$count" -gt 1 ]; then
		echo universal
		return 0
	fi
	abi=$(head -1 <<<"$native_abis")
	case "$abi" in
	arm64-v8a) echo arm64-v8a ;;
	armeabi-v7a) echo arm-v7a ;;
	x86_64) echo x86_64 ;;
	x86) echo x86 ;;
	*) return 1 ;;
	esac
}

validate_standalone_derivation() {
	# Store metadata is a hint, never permission to turn a flattened fat APK into
	# an ABI-specific output. Re-inspect the downloaded bytes before publishing
	# a planned branch so metadata/payload contradictions fail closed.
	local apk=$1 arch=$2 derivable
	derivable=$(standalone_apk_build_arches "$apk") || return 2
	if grep -qx "$arch" <<<"$derivable"; then return 0; fi
	if [ "$arch" = universal ]; then
		epr "Planned universal standalone APK is actually derivable only as '${derivable}'"
	else
		epr "Planned '$arch' standalone APK is actually derivable only as '${derivable}'"
	fi
	return 1
}

validate_optional_auto_abi() {
	local stock_apk=$1 arch=$2 record=${3:-true} requested available count reason
	[ "$arch" != universal ] || return 0
	requested=$(android_abi_for_build_arch "$arch") || return 2
	if ! available=$(stock_native_abis "$stock_apk"); then
		return 2
	fi
	count=$(grep -c . <<<"$available" || :)
	if [ "$count" -eq 0 ]; then
		reason="Standalone stock APK is ABI-independent; only universal is derivable"
	elif [ "$count" -gt 1 ]; then
		reason="Standalone stock APK is multi-ABI [$(paste -sd, <<<"$available")]; only universal is derivable without split boundaries"
	elif ! grep -qx "$requested" <<<"$available"; then
		reason="Stock APK has native ABIs [$(paste -sd, <<<"$available")] but not ${requested}"
	else
		return 0
	fi
	OPTIONAL_ABI_UNAVAILABLE_REASON=$reason
	if [ "$record" = true ] && [ "${BUILD_OPTIONAL_VARIANT:-false}" = true ]; then record_optional_variant_skip "$reason" || :; fi
	return 1
}

source_arch_score() {
	# Print a positive compatibility score for a source variant descriptor.
	# Higher scores are preferred. Multi-ABI descriptors are parsed as sets
	# rather than matched as exact presentation strings.
	local descriptor=${1,,} requested=$2 requested_abi tokens count
	descriptor=$(xargs <<<"$descriptor")
	case "$descriptor" in
		universal)
			if [ "$requested" = universal ]; then echo 1000; else echo 800; fi
			return 0
			;;
		noarch)
			if [ "$requested" = universal ]; then echo 900; else echo 100; fi
			return 0
			;;
	esac
	tokens=$(tr '+,/' '   ' <<<"$descriptor" | tr -s '[:space:]' '\n' \
		| grep -E '^(arm64-v8a|armeabi-v7a|x86|x86_64)$' | sort -u || :)
	count=$(grep -c . <<<"$tokens" || :)
	if [ "$requested" = universal ]; then
		[ "$count" -ge 2 ] || return 1
		echo $((500 + count))
		return 0
	fi
	requested_abi=$(android_abi_for_build_arch "$requested") || return 1
	grep -qx "$requested_abi" <<<"$tokens" || return 1
	# Prefer a compact exact-ABI source over a wider source for ABI builds.
	echo $((900 - count))
}

source_artifact_arch_score() {
	# Metadata architecture labels describe where an artifact can run. Standalone
	# APKs cannot be repartitioned after a store has flattened the split bundle,
	# so only split containers inherit the broad descriptor semantics above.
	local descriptor=$1 requested=$2 format=${3,,} tokens count requested_abi
	case "$format" in
		bundle|apkm|apks|xapk|split)
			source_arch_score "$descriptor" "$requested"
			return
			;;
	esac
	descriptor=$(xargs <<<"${descriptor,,}")
	if [ "$descriptor" = noarch ] || [ "$descriptor" = universal ]; then
		[ "$requested" = universal ] || return 1
		echo 1000
		return 0
	fi
	tokens=$(tr '+,/' '   ' <<<"$descriptor" | tr -s '[:space:]' '\n' \
		| grep -E '^(arm64-v8a|armeabi-v7a|x86|x86_64)$' | sort -u || :)
	count=$(grep -c . <<<"$tokens" || :)
	if [ "$count" -ge 2 ]; then
		[ "$requested" = universal ] || return 1
		echo $((900 + count))
		return 0
	fi
	[ "$count" -eq 1 ] || return 1
	[ "$requested" != universal ] || return 1
	requested_abi=$(android_abi_for_build_arch "$requested") || return 1
	grep -qx "$requested_abi" <<<"$tokens" || return 1
	echo 1000
}

source_format_score() {
	# Split containers are first-class stock inputs. For ABI-specific builds they
	# are preferred over standalone APKs because stock_bundle.py can keep every
	# language/density/feature split while dropping only foreign CPU payloads.
	local format=${1,,}
	case "$format" in
		bundle|apkm|apks|xapk) echo 250 ;;
		apk) echo 0 ;;
		*) echo 0 ;;
	esac
}

dpi_value() {
	case "${1,,}" in
		ldpi|120dpi|120) echo 120 ;;
		mdpi|160dpi|160) echo 160 ;;
		tvdpi|213dpi|213) echo 213 ;;
		hdpi|240dpi|240) echo 240 ;;
		xhdpi|320dpi|320) echo 320 ;;
		xxhdpi|480dpi|480) echo 480 ;;
		xxxhdpi|640dpi|640) echo 640 ;;
		*) return 1 ;;
	esac
}

source_dpi_score() {
	# An unspecified DPI is not a nodpi-only request. Split bundles commonly use
	# range descriptors such as 120-640dpi; accepting them is required to retain
	# all density splits during ABI-selective normalization.
	local descriptor=${1,,} requested=${2,,} requested_value low high
	descriptor=$(xargs <<<"$descriptor")
	requested=$(xargs <<<"$requested")
	if [ -z "$requested" ]; then
		echo 0
		return 0
	fi
	case "$descriptor" in
		"$requested") echo 40; return 0 ;;
		nodpi|anydpi) echo 20; return 0 ;;
	esac
	if [[ $descriptor =~ ^([0-9]+)-([0-9]+)dpi$ ]]; then
		low=${BASH_REMATCH[1]}; high=${BASH_REMATCH[2]}
		requested_value=$(dpi_value "$requested") || return 1
		if (( requested_value >= low && requested_value <= high )); then
			echo 30
			return 0
		fi
	fi
	return 1
}

source_dpi_breadth_score() {
	local descriptor=${1,,} low high
	descriptor=$(xargs <<<"$descriptor")
	case "$descriptor" in
		nodpi|anydpi) echo 3000; return 0 ;;
	esac
	if [[ $descriptor =~ ^([0-9]+)-([0-9]+)dpi$ ]]; then
		low=${BASH_REMATCH[1]}; high=${BASH_REMATCH[2]}
		echo $((2000 + high - low + 640 - low))
		return 0
	fi
	if dpi_value "$descriptor" >/dev/null 2>&1; then
		echo 1000
	else
		echo 0
	fi
}

source_sdk_breadth_score() {
	# Lower minimum Android versions cover more devices. Keep this a soft
	# tiebreaker after ABI coverage, not a hard compatibility requirement.
	local descriptor=${1,,} major minor
	if [[ $descriptor =~ android[[:space:]]+([0-9]+)(\.([0-9]+))? ]]; then
		major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[3]:-0}
		echo $((5000 - major * 100 - minor))
	else
		echo 0
	fi
}

source_arch_breadth_score() {
	local descriptor=${1,,} tokens count
	descriptor=$(xargs <<<"$descriptor")
	case "$descriptor" in
		universal) echo 5; return 0 ;;
		noarch) echo 1; return 0 ;;
	esac
	tokens=$(tr '+,/' '   ' <<<"$descriptor" | tr -s '[:space:]' '\n' \
		| grep -E '^(arm64-v8a|armeabi-v7a|x86|x86_64)$' | sort -u || :)
	count=$(grep -c . <<<"$tokens" || :)
	echo "$count"
}

source_arch_coverage_score() {
	local descriptor=$1 arches_json=$2 arch score=0
	while IFS= read -r arch; do
		[ -n "$arch" ] || continue
		if source_arch_score "$descriptor" "$arch" >/dev/null 2>&1; then
			score=$((score + 1))
		fi
	done < <(jq -r '.[] | if type == "string" then . else .arch end' <<<"$arches_json")
	[ "$score" -gt 0 ] || return 1
	echo "$score"
}

ensure_apkeditor() {
	local override=${APKEDITOR_JAR:-} cache_root release asset_meta name url digest expected actual jar
	if [ -n "$override" ] && [ -f "$override" ]; then
		printf '%s\n' "$override"
		return 0
	fi
	if [ "$_APKEDITOR_URL_EXPLICIT" = x ]; then
		# Preserve the operator URL override from the pre-cache implementation,
		# but keep unpinned executable bytes job-local instead of persisting them.
		jar="${TEMP_DIR}/apkeditor.jar"
		if [ ! -f "$jar" ]; then
			gh_dl "$jar" "$APKEDITOR_URL" >/dev/null || return 1
		fi
		printf '%s\n' "$jar"
		return 0
	fi
	cache_root=$(patched_kushion_cache_dir)
	release=$(gh_req "https://api.github.com/repos/${APKEDITOR_REPOSITORY}/releases/tags/V${APKEDITOR_VERSION}" -) || return 1
	name="APKEditor-${APKEDITOR_VERSION}.jar"
	asset_meta=$(jq -e --arg name "$name" '.assets[] | select(.name == $name)' <<<"$release") || return 1
	url=$(jq -r '.url // empty' <<<"$asset_meta")
	digest=$(jq -r '.digest // empty' <<<"$asset_meta")
	[ -n "$url" ] || return 1
	if [[ $digest =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
		expected=${digest#sha256:}; expected=${expected,,}
		jar="${cache_root}/tools/apkeditor/${APKEDITOR_VERSION}/${name}"
	else
		# Do not persist an executable JAR that cannot be revalidated after a
		# cache restore. The job-local fallback still preserves compatibility.
		expected=""
		jar="${TEMP_DIR}/apkeditor.jar"
	fi
	mkdir -p "$(dirname "$jar")"
	if [ -f "$jar" ] && [ -n "$expected" ]; then
		actual=$(sha256sum "$jar" | awk '{print tolower($1)}')
		if [ "$actual" != "$expected" ]; then
			wpr "Discarding cached APKEditor with an unexpected SHA-256"
			rm -f "$jar"
		fi
	fi
	if [ ! -f "$jar" ]; then
		gh_dl "$jar" "$url" >/dev/null || return 1
	fi
	if [ -n "$expected" ]; then
		actual=$(sha256sum "$jar" | awk '{print tolower($1)}')
		if [ "$actual" != "$expected" ]; then
			epr "APKEditor SHA-256 mismatch: expected $expected, got $actual"
			rm -f "$jar"
			return 1
		fi
	fi
	printf '%s\n' "$jar"
}

apply_launcher_branding() {
	local input=$1 launcher_name=$2 icon_overlay=$3 output=$4
	[ -n "$launcher_name" ] || [ -n "$icon_overlay" ] || { cp -f "$input" "$output"; return 0; }
	local jar decoded overlay_path report
	jar=$(ensure_apkeditor) || return 1
	decoded=$(mktemp -d -p "$TEMP_DIR" launcher-branding.XXXXXX)
	report="${output}.branding.json"
	if [ -n "$icon_overlay" ]; then
		overlay_path=$icon_overlay
		[[ $overlay_path = /* ]] || overlay_path="$CWD/$overlay_path"
		if [ ! -e "$overlay_path" ]; then
			epr "Launcher icon overlay does not exist: $icon_overlay"
			rm -rf "$decoded"
			return 1
		fi
	fi
	if ! OP=$(java -jar "$jar" d -t xml -dex -i "$input" -o "$decoded" -f 2>&1); then
		epr "APKEditor launcher-brand decode error: $OP"
		rm -rf "$decoded"
		return 1
	fi
	local edit_args=(--decoded "$decoded" --report "$report")
	[ -n "$launcher_name" ] && edit_args+=(--name "$launcher_name")
	[ -n "$icon_overlay" ] && edit_args+=(--icon-overlay "$overlay_path")
	if ! python3 "$CWD/scripts/launcher_branding.py" "${edit_args[@]}"; then
		rm -rf "$decoded"
		return 1
	fi
	if ! OP=$(java -jar "$jar" b -i "$decoded" -o "$output" -f 2>&1); then
		epr "APKEditor launcher-brand build error: $OP"
		rm -rf "$decoded" "$output"
		return 1
	fi
	rm -rf "$decoded"
}

select_bundle_splits() {
	local bundle=$1 arch=$2 output_dir=$3 manifest=${4-}
	local args=(select --bundle "$bundle" --arch "$arch" --output-dir "$output_dir")
	[ -n "$manifest" ] && args+=(--manifest "$manifest")
	python3 "$CWD/scripts/stock_bundle.py" "${args[@]}" >/dev/null
}

merge_split_dir_unsigned() {
	local selected=$1 output=$2
	pr "Merging selected splits without release signing"
	local apkeditor_jar
	apkeditor_jar=$(ensure_apkeditor) || return 1
	rm -f "$output"
	if ! OP=$(java -jar "$apkeditor_jar" merge -i "$selected" -o "$output" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		rm -f "$output"
		return 1
	fi
	return 0
}

merge_splits() {
	local bundle=$1 output=$2 arch=${3:-universal}
	local selected manifest
	selected=$(mktemp -d -p "$TEMP_DIR")
	manifest="${output}.bundle-selection.json"
	pr "Selecting '$arch' splits from $(basename "$bundle")"
	if ! select_bundle_splits "$bundle" "$arch" "$selected" "$manifest"; then
		rm -rf "$selected"
		epr "Could not select a coherent split set for '$arch' from '$bundle'"
		return 1
	fi
	if ! merge_split_dir_unsigned "$selected" "$output"; then
		rm -rf "$selected"
		return 1
	fi
	rm -rf "$selected"
	return 0
}

materialize_partition_splits() {
	local partition_root=$1 arch=$2 output_dir=$3 manifest=${4-}
	local args=(materialize --partition-root "$partition_root" --arch "$arch" --output-dir "$output_dir")
	[ -n "$manifest" ] && args+=(--manifest "$manifest")
	python3 "$CWD/scripts/stock_bundle.py" "${args[@]}" >/dev/null
}

merge_partitioned_stock() {
	local partition_root=$1 output=$2 arch=$3 selected manifest
	selected=$(mktemp -d -p "$TEMP_DIR")
	manifest="${output}.bundle-selection.json"
	pr "Materializing shared '$arch' stock splits"
	if ! materialize_partition_splits "$partition_root" "$arch" "$selected" "$manifest"; then
		rm -rf "$selected"
		return 1
	fi
	SHARED_SOURCE_SELECTED_SPLITS_DIR="$selected"
	if ! merge_split_dir_unsigned "$selected" "$output"; then
		rm -rf "$selected"
		SHARED_SOURCE_SELECTED_SPLITS_DIR=""
		return 1
	fi
	return 0
}

is_split_container() {
	case "${1##*.}" in
	apkm|apks|xapk) return 0 ;;
	*) return 1 ;;
	esac
}

download_split_container_apkmirror() {
	local url=$1 output=$2 arch=$3 referer=$4 candidate
	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "$output" "$arch"
		return $?
	fi
	candidate="${output}.candidate.bundle"
	rm -f "$candidate"
	apkmirror_req "$url" "$candidate" "$referer" || { rm -f "$candidate"; return 1; }
	if ! merge_splits "$candidate" "$output" "$arch"; then
		rm -f "$candidate" "${output}.bundle-selection.json"
		return 1
	fi
	mv -f "$candidate" "${output}.bundle"
}

download_split_container() {
	local url=$1 output=$2 arch=$3 candidate
	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "$output" "$arch"
		return $?
	fi
	candidate="${output}.candidate.bundle"
	rm -f "$candidate"
	req "$url" "$candidate" || { rm -f "$candidate"; return 1; }
	if ! merge_splits "$candidate" "$output" "$arch"; then
		rm -f "$candidate" "${output}.bundle-selection.json"
		return 1
	fi
	mv -f "$candidate" "${output}.bundle"
}

# -------------------- apkmirror --------------------
apkmirror_inventory() {
	local resp="$1" node app_table emptyCheck format source_arch sdk_desc dpi_desc dlurl first=true
	printf '['
	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		[ -n "$node" ] || break
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		[ -n "$emptyCheck" ] || break
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		format=$(sed -n 3p <<<"$app_table")
		isoneof "$format" APK BUNDLE || continue
		source_arch=$(sed -n 4p <<<"$app_table")
		sdk_desc=$(sed -n 5p <<<"$app_table")
		dpi_desc=$(sed -n 6p <<<"$app_table")
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		$first || printf ','
		first=false
		jq -cn --arg format "$format" --arg arch "$source_arch" --arg minAndroid "$sdk_desc" --arg dpi "$dpi_desc" --arg url "$dlurl" \
			'{format:$format,arch:$arch,minAndroid:$minAndroid,dpi:$dpi,url:$url}'
	done
	printf ']\n'
}

apkmirror_search_shared() {
	local resp="$1" dpi="$2" arches_json="$3"
	local dlurl="" node app_table emptyCheck source_arch format dpi_desc sdk_desc
	local coverage breadth dpi_score sdk_score dpi_breadth score
	local best_url="" best_score=-1 best_arch="" best_dpi="" best_sdk=""

	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ -z "$emptyCheck" ]; then break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		format=$(sed -n 3p <<<"$app_table")
		[ "$format" = BUNDLE ] || continue
		source_arch=$(sed -n 4p <<<"$app_table")
		sdk_desc=$(sed -n 5p <<<"$app_table")
		dpi_desc=$(sed -n 6p <<<"$app_table")
		if ! dpi_score=$(source_dpi_score "$dpi_desc" "$dpi"); then continue; fi
		if ! coverage=$(source_arch_coverage_score "$source_arch" "$arches_json"); then continue; fi
		breadth=$(source_arch_breadth_score "$source_arch")
		sdk_score=$(source_sdk_breadth_score "$sdk_desc")
		dpi_breadth=$(source_dpi_breadth_score "$dpi_desc")
		# Requested coverage dominates, then prefer an intrinsically broader
		# bundle even if this run only needs one ABI. SDK and density breadth
		# break the remaining ties.
		score=$((coverage * 1000000000 + breadth * 10000000 + sdk_score * 1000 + dpi_breadth + dpi_score))
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		if [ "$score" -gt "$best_score" ]; then
			best_score=$score
			best_url=$dlurl
			best_arch=$source_arch
			best_dpi=$dpi_desc
			best_sdk=$sdk_desc
		fi
	done
	[ -n "$best_url" ] || return 1
	printf '%s\t%s\t%s\t%s\n' "$best_url" "$best_arch" "$best_sdk" "$best_dpi"
}

apkmirror_release_page() {
	local url=$1 version=${2// /-} apkmname
	apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
	apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
	printf '%s/%s-%s-release/\n' "$url" "$apkmname" "${version//./-}"
}

dl_apkmirror_shared() {
	local url=$1 version=$2 output=$3 arches_json=$4 dpi=$5
	local release_url resp dlurl source_arch sdk_desc dpi_desc download_page intermediate final_url
	release_url=$(apkmirror_release_page "$url" "$version") || return 1
	resp=$(apkmirror_req "$release_url" - "$url") || return 1
	apkmirror_inventory "$resp" >"${output}.inventory.json" || return 1
	IFS=$'\t' read -r dlurl source_arch sdk_desc dpi_desc < <(apkmirror_search_shared "$resp" "$dpi" "$arches_json") || return 1
	[ -n "$dlurl" ] || return 1
	pr "Selected APKMirror shared bundle: arch='$source_arch', sdk='$sdk_desc', dpi='$dpi_desc'"
	download_page=$(apkmirror_req "$dlurl" - "$release_url") || return 1
	intermediate=$(echo "$download_page" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	[ -n "$intermediate" ] || return 1
	final_url=$(apkmirror_req "$intermediate" - "$dlurl" | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1
	[ -n "$final_url" ] || return 1
	apkmirror_req "$final_url" "$output" "$intermediate" || return 1
	jq -n \
		--arg source apkmirror \
		--arg releaseUrl "$release_url" \
		--arg variantUrl "$dlurl" \
		--arg descriptor "$source_arch" \
		--arg minAndroid "$sdk_desc" \
		--arg dpi "$dpi_desc" \
		'{schemaVersion:1,source:$source,releaseUrl:$releaseUrl,variantUrl:$variantUrl,format:"BUNDLE",advertisedArch:$descriptor,minAndroid:$minAndroid,dpi:$dpi}' \
		>"${output}.source.json"
}


apkmirror_resolve_variant_binary() {
	local variant_url=$1 release_url=$2 download_page intermediate final_url
	download_page=$(apkmirror_req "$variant_url" - "$release_url") || return 1
	intermediate=$(echo "$download_page" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	[ -n "$intermediate" ] || return 1
	final_url=$(apkmirror_req "$intermediate" - "$variant_url" | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1
	[ -n "$final_url" ] || return 1
	printf '%s\t%s\n' "$final_url" "$intermediate"
}

apkmirror_download_binary() {
	local url=$1 output=$2 referer=$3 tmp="${output}.tmp.$$"
	mkdir -p "$(dirname "$output")"
	rm -f "$tmp"
	if ! curl -L -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 1 --fail -s -S \
		-H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0" \
		-H "Referer: $referer" -H "Accept-Language: en-US,en;q=0.9" \
		"$url" -o "$tmp"; then
		request_failure "APKMirror binary download failed: $url"
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$output"
}

prepare_apkmirror_download_plan() {
	local url=$1 version=$2 arches_json=$3 dpi=$4 output=$5 release_url resp inventory
	release_url=$(apkmirror_release_page "$url" "$version") || return 1
	resp=$(apkmirror_req "$release_url" - "$url") || return 1
	inventory="${output}.inventory.json"
	apkmirror_inventory "$resp" >"$inventory" || return 1
	python3 "$CWD/scripts/source_plan.py" --inventory "$inventory" --arches-json "$arches_json" --dpi "$dpi" --output "$output" >/dev/null || return 1
	jq -e '.complete == true and (.artifacts | length) > 0' "$output" >/dev/null || return 1
	jq --arg releaseUrl "$release_url" '. + {source:"apkmirror",releaseUrl:$releaseUrl}' "$output" >"${output}.tmp"
	mv -f "${output}.tmp" "$output"
}

execute_apkmirror_download_plan() {
	local plan=$1 download_root=$2 resolved=$3 count index id variant final referer local_file
	mkdir -p "$download_root"
	cp -f "$plan" "$resolved"
	count=$(jq '.artifacts | length' "$plan")
	# Resolve all transient download links first.  The expensive APK/APKM/APKS
	# payload transfers only begin after the complete set is known.
	for ((index=0; index<count; index++)); do
		id=$(jq -r ".artifacts[$index].id" "$plan")
		variant=$(jq -r ".artifacts[$index].url" "$plan")
		IFS=$'\t' read -r final referer < <(apkmirror_resolve_variant_binary "$variant" "$(jq -r .releaseUrl "$plan")") || return 1
		local_file="$download_root/${id}.stock"
		jq --argjson i "$index" --arg final "$final" --arg referer "$referer" --arg localFile "$local_file" \
			'.artifacts[$i] += {finalUrl:$final,referer:$referer,localFile:$localFile}' "$resolved" >"${resolved}.tmp"
		mv -f "${resolved}.tmp" "$resolved"
	done

	local pids=() failed=0
	while IFS=$'\t' read -r final local_file referer; do
		REQUEST_FAILURE_LEVEL=notice apkmirror_download_binary "$final" "$local_file" "$referer" &
		pids+=("$!")
	done < <(jq -r '.artifacts[] | [.finalUrl,.localFile,.referer] | @tsv' "$resolved")
	for id in "${pids[@]}"; do
		wait "$id" || failed=1
	done
	[ "$failed" -eq 0 ] || return 1
}

materialize_apkmirror_download_plan() {
	local plan=$1 out=$2 pkg_name=$3 arch source_id format local_file branch_dir sig_op manifest optional
	mkdir -p "$out/branches"
	while IFS=$'\t' read -r arch source_id; do
		[ -n "$arch" ] || continue
		format=$(jq -r --arg id "$source_id" '.artifacts[] | select(.id==$id) | .format' "$plan")
		local_file=$(jq -r --arg id "$source_id" '.artifacts[] | select(.id==$id) | .localFile' "$plan")
		[ -f "$local_file" ] || return 1
		branch_dir="$out/branches/$arch"
		rm -rf "$branch_dir"; mkdir -p "$branch_dir"
		if [ "$format" = BUNDLE ]; then
			mkdir -p "$branch_dir/splits"
			manifest="$branch_dir/selection.json"
			python3 "$CWD/scripts/stock_bundle.py" select --bundle "$local_file" --arch "$arch" --output-dir "$branch_dir/splits" --manifest "$manifest" >/dev/null || return 1
			while IFS= read -r -d '' split_apk; do
				if ! sig_op=$(check_sig "$split_apk" "$pkg_name" apkmirror 2>&1); then
					epr "Planned source signature mismatch '$split_apk': $sig_op"
					return 1
				fi
			done < <(find "$branch_dir/splits" -type f -name '*.apk' -print0)
		else
			if ! validate_standalone_derivation "$local_file" "$arch"; then
				epr "APKMirror standalone payload contradicts the planned '$arch' artifact capability"
				return 1
			fi
			if ! sig_op=$(check_sig "$local_file" "$pkg_name" apkmirror 2>&1); then
				epr "Planned stock APK signature mismatch '$local_file': $sig_op"
				return 1
			fi
			cp -f "$local_file" "$branch_dir/stock.apk"
		fi
		jq -n --arg arch "$arch" --arg sourceId "$source_id" --arg format "$format" \
			'{schemaVersion:1,arch:$arch,sourceId:$sourceId,format:$format,validated:true}' >"$branch_dir/branch.json"
	done < <(jq -r '.branchSources | to_entries[] | [.key,.value] | @tsv' "$plan")

	# The planner may deliberately leave optional architectures uncovered. Emit a
	# tiny branch artifact for each of them so the architecture job can turn that
	# into a deterministic skip instead of failing actions/download-artifact.
	while IFS=$'\t' read -r arch optional; do
		[ -n "$arch" ] || continue
		jq -e --arg arch "$arch" '.branchSources[$arch] != null' "$plan" >/dev/null && continue
		[ "$optional" = true ] || return 1
		branch_dir="$out/branches/$arch"
		rm -rf "$branch_dir"; mkdir -p "$branch_dir"
		jq -n --arg arch "$arch" --arg reason "APKMirror source plan has no compatible $arch artifact" \
			'{schemaVersion:1,available:false,optional:true,arch:$arch,reason:$reason}' >"$branch_dir/branch.json"
	done < <(jq -r '.requestedArches[] as $arch | [$arch, ((.requiredArches | index($arch)) == null)] | @tsv' "$plan")
}

prepare_apkmirror_planned_source() {
	local pkg_name=$1 version=$2 dpi=$3 arches_json=$4 out=$5
	local plan="$TEMP_DIR/apkmirror-download-plan.json" resolved="$TEMP_DIR/apkmirror-resolved-plan.json" downloads="$TEMP_DIR/apkmirror-planned-downloads"
	[ -n "${args[apkmirror_dlurl]-}" ] || return 1
	rm -rf "$downloads" "$out/branches"; rm -f "$plan" "$resolved" "${plan}.inventory.json"
	if ! acquisition_source_resp apkmirror "${args[apkmirror_dlurl]}"; then return 1; fi
	if ! REQUEST_FAILURE_LEVEL=notice prepare_apkmirror_download_plan "${args[apkmirror_dlurl]}" "$version" "$arches_json" "$dpi" "$plan"; then return 1; fi
	pr "Planned $(jq -r .artifactCount "$plan") APKMirror stock download(s) for ${version}; starting payload downloads together"
	REQUEST_FAILURE_LEVEL=notice execute_apkmirror_download_plan "$plan" "$downloads" "$resolved" || return 1
	materialize_apkmirror_download_plan "$resolved" "$out" "$pkg_name" || return 1
	cp -f "$resolved" "$out/download-plan.json"
	jq -n \
		--arg target "${BUILD_TARGET:-}" --arg package "$pkg_name" --arg version "$version" \
		--argjson requestedArches "$arches_json" --slurpfile plan "$out/download-plan.json" \
		'{schemaVersion:2,status:"ready",shared:true,strategy:"branches",target:$target,packageName:$package,version:$version,sourceName:"apkmirror",trustClass:"third-party-mirror",sourceProvenanceFamily:"apkmirror",sourceProvenanceDomain:"apkmirror.com",signerPinRequired:true,signerVerified:true,requestedArches:$requestedArches,downloadPlan:$plan[0],availableBuildArches:($plan[0].branchSources|keys),coverage:{required:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch]),available:($plan[0].branchSources|keys),missingRequired:([$requestedArches[] | if type == "string" then {arch:.,optional:false} else . end | select((.optional // false) != true) | .arch] - ($plan[0].branchSources|keys))}}' \
		>"$out/source.json"
	local available_json
	available_json=$(jq -c '.availableBuildArches // []' "$out/source.json") || return 1
	annotate_source_coverage "$out/source.json" "$arches_json" "$available_json" || return 1
	return 0
}

apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3"
	local dlurl="" node app_table emptyCheck source_arch format dpi_desc
	local arch_score format_score dpi_score score
	local best_url="" best_format="" best_score=-1

	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ -z "$emptyCheck" ]; then break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		format=$(sed -n 3p <<<"$app_table")
		if ! isoneof "$format" APK BUNDLE; then continue; fi
		dpi_desc=$(sed -n 6p <<<"$app_table")
		if ! dpi_score=$(source_dpi_score "$dpi_desc" "$dpi"); then continue; fi
		source_arch=$(sed -n 4p <<<"$app_table")
		if ! arch_score=$(source_artifact_arch_score "$source_arch" "$arch" "$format"); then continue; fi
		format_score=$(source_format_score "$format")
		score=$((arch_score + format_score + dpi_score))
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		if [ "$score" -gt "$best_score" ]; then
			best_score=$score
			best_url=$dlurl
			best_format=$format
		fi
	done
	[ -n "$best_url" ] || return 1
	printf '%s\t%s\n' "$best_format" "$best_url"
}

dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false
	local build_arch=$arch

	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "${output}" "$build_arch"
		return 0
	fi

	local resp node app_table dlurl="" selected_format=""
	url=$(apkmirror_release_page "$url" "$version") || return 1
	resp=$(apkmirror_req "$url" - "${args[apkmirror_dlurl]-https://www.apkmirror.com/}") || return 1
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		IFS=$'\t' read -r selected_format dlurl < <(apkmirror_search "$resp" "$dpi" "$build_arch") || return 1
		[ -n "$dlurl" ] || return 1
		if [ "$selected_format" = BUNDLE ]; then is_bundle=true; else is_bundle=false; fi
		resp=$(apkmirror_req "$dlurl" - "$url") || return 1
	fi
	local variant_url=${dlurl:-$url}
	url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	local intermediate_url=$url
	url=$(apkmirror_req "$intermediate_url" - "$variant_url" | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1

	if [ "$is_bundle" = true ]; then
		download_split_container_apkmirror "$url" "$output" "$build_arch" "$intermediate_url"
	else
		apkmirror_req "$url" "${output}" "$intermediate_url" || return 1
	fi
}
get_apkmirror_vers() {
	local vers apkm_resp
	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" -)
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')
	if [ "$__AAV__" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}
get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }
get_apkmirror_resp() {
	__APKMIRROR_RESP__=$(apkmirror_req "${1}" -) || return 1
	__APKMIRROR_CAT__="${1##*/}"
}

acquisition_source_resp() {
	# Acquisition may revisit the same provider once per missing branch. Cache
	# only failures: successful parsers populate provider-specific globals and
	# therefore still run normally when their state is needed again.
	local source_name=$1 locator=$2 key="${1}|${2}"
	if [ "${SOURCE_ACQUISITION_NEGATIVE_RESP[$key]+yes}" = yes ]; then
		npr "Skipping repeated failed '${source_name}' metadata request during this acquisition"
		return 1
	fi
	if ! REQUEST_FAILURE_LEVEL=notice "get_${source_name}_resp" "$locator"; then
		SOURCE_ACQUISITION_NEGATIVE_RESP[$key]=1
		return 1
	fi
}

# -------------------- APKFab --------------------
apkfab_versions_url() {
	local locator=${1%/}
	if [[ $locator == */versions ]]; then printf '%s\n' "$locator"; else printf '%s/versions\n' "$locator"; fi
}

get_apkfab_resp() {
	local locator=${1%/} url
	url=$(apkfab_versions_url "$locator")
	__APKFAB_LOCATOR__=${locator%/versions}
	__APKFAB_RESP__=$(req "$url" - -H "Referer: ${__APKFAB_LOCATOR__}/") || return 1
	# A valid APKFab history page exposes at least one version span. Treat WAF or
	# interstitial HTML as metadata-unavailable instead of advertising garbage.
	python3 "$CWD/scripts/apkfab_inventory.py" versions --html - <<<"$__APKFAB_RESP__" | grep -q . || return 1
}

get_apkfab_vers() {
	python3 "$CWD/scripts/apkfab_inventory.py" versions --html - <<<"$__APKFAB_RESP__"
}

get_apkfab_pkg_name() {
	local locator=${__APKFAB_LOCATOR__:-}
	[ -n "$locator" ] || return 1
	printf '%s\n' "${locator##*/}"
}

apkfab_resolve_payload_url() {
	local page_url=$1 page_html=$2
	python3 "$CWD/scripts/apkfab_inventory.py" resolve --html "$page_html" --page-url "$page_url"
}

apkfab_resolve_payload_urls() {
	local page_url=$1 page_html=$2
	python3 "$CWD/scripts/apkfab_inventory.py" resolve-all --html "$page_html" --page-url "$page_url"
}

is_zip_payload() {
	python3 - "$1" <<'PYZIP'
import sys
import zipfile
raise SystemExit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)
PYZIP
}

apkfab_download_payload() {
	local page_url=$1 output=$2 arch=$3 referer=$4
	local -a queue=("$page_url") refs=("$referer") next_urls=()
	local -A seen=()
	local index=0 attempts=0 url current_referer candidate next
	__APKFAB_PAYLOAD_URL__=

	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "$output" "$arch" || return 1
		__APKFAB_PAYLOAD_URL__="$page_url"
		return 0
	fi

	while [ "$index" -lt "${#queue[@]}" ] && [ "$attempts" -lt 8 ]; do
		url=${queue[$index]}
		current_referer=${refs[$index]}
		index=$((index + 1))
		[ -z "${seen[$url]+x}" ] || continue
		seen[$url]=1
		attempts=$((attempts + 1))
		candidate="$TEMP_DIR/apkfab-payload-${attempts}.candidate"
		rm -f "$candidate"
		if ! req "$url" "$candidate" -H "Referer: $current_referer"; then
			continue
		fi

		if is_zip_payload "$candidate"; then
			pr "Validating APKFab ZIP payload candidate $attempts for '$arch'"
			if merge_splits "$candidate" "$output" "$arch"; then
				mv -f "$candidate" "${output}.bundle"
				__APKFAB_PAYLOAD_URL__="$url"
				return 0
			fi
			rm -f "$candidate" "${output}.bundle-selection.json"
			npr "APKFab ZIP candidate could not derive '$arch'; trying another resolved payload"
			continue
		fi

		npr "APKFab candidate returned non-ZIP content; inspecting it for the next payload hop"
		next_urls=()
		mapfile -t next_urls < <(apkfab_resolve_payload_urls "$url" "$candidate" 2>/dev/null || :)
		rm -f "$candidate"
		for next in "${next_urls[@]}"; do
			[ -n "$next" ] || continue
			[ -z "${seen[$next]+x}" ] || continue
			queue+=("$next")
			refs+=("$url")
		done
	done

	npr "APKFab download traversal exhausted ${attempts} candidate(s) without a valid '$arch' XAPK"
	return 1
}

dl_apkfab() {
	local locator=${1%/} version=${2#v} output=$3 arch=$4 _dpi=$5
	local selected sha1 page_url direct_url
	[ -n "${__APKFAB_RESP__:-}" ] || get_apkfab_resp "$locator" || return 1
	selected=$(python3 "$CWD/scripts/apkfab_inventory.py" select \
		--html - --version "$version" --arch "$arch" --base-url "${__APKFAB_LOCATOR__:-$locator}" \
		<<<"$__APKFAB_RESP__") || {
		npr "APKFab exact-version node has no '$arch' variant for '$version'"
		return 1
	}
	sha1=$(jq -r '.sha1 // empty' <<<"$selected")
	page_url=$(jq -r '.downloadPage // empty' <<<"$selected")
	[ -n "$sha1" ] && [ -n "$page_url" ] || return 1
	pr "Downloading APKFab exact-version variant: version='$version', arch='$arch', sha1='$sha1'"
	if ! apkfab_download_payload "$page_url" "$output" "$arch" "${__APKFAB_LOCATOR__:-$locator}/versions"; then
		npr "APKFab exact-version payload traversal failed for '$version' '$arch' (sha1=$sha1)"
		return 1
	fi
	direct_url=${__APKFAB_PAYLOAD_URL__:-$page_url}
	jq -n --arg source apkfab --arg url "$direct_url" --arg sha1 "$sha1" --arg version "$version" --arg arch "$arch" \
		'{schemaVersion:1,source:$source,url:$url,sha1:$sha1,version:$version,arch:$arch,format:"XAPK"}' >"${output}.source.json"
}

# -------------------- Aptoide --------------------
aptoide_inventory_request() {
	local pkg=$1 endpoint
	endpoint="https://ws75.aptoide.com/api/7/app/get/package_name=${pkg}/nodes=meta,versions/aab=1"
	req "$endpoint" - -H 'Accept: application/json'
}

get_aptoide_resp() {
	local pkg=$1 response legacy_endpoint
	if response=$(aptoide_inventory_request "$pkg" 2>/dev/null) && \
	   python3 "$CWD/scripts/aptoide_inventory.py" versions --json - <<<"$response" | grep -q .; then
		__APTOIDE_RESP__=$response
		return 0
	fi
	# Keep the older getMeta endpoint as a compatibility fallback. It only
	# advertises one version, but is still preferable to discarding Aptoide when
	# app/get is unavailable from a runner region.
	legacy_endpoint="https://ws2.aptoide.com/api/7/app/getMeta/package_name=${pkg}"
	response=$(req "$legacy_endpoint" -) || return 1
	if ! jq -e --arg pkg "$pkg" '
		(.data.package // "") == $pkg and
		(.data.file.vername // "" | length > 0) and
		((.data.file.path // .data.file.path_alt // "") | length > 0)
	' >/dev/null <<<"$response"; then
		return 1
	fi
	__APTOIDE_RESP__=$response
}
get_aptoide_vers() { python3 "$CWD/scripts/aptoide_inventory.py" versions --json - <<<"$__APTOIDE_RESP__"; }
get_aptoide_pkg_name() {
	jq -r '.nodes.meta.data.package // .data.package // empty' <<<"$__APTOIDE_RESP__"
}
dl_aptoide() {
	local _pkg=$1 version=$2 output=$3 arch=$4 _dpi=$5 selected actual url format
	selected=$(python3 "$CWD/scripts/aptoide_inventory.py" select --json - --version "$version" --arch "$arch" <<<"$__APTOIDE_RESP__") || {
		actual=$(get_aptoide_vers | paste -sd, -)
		npr "Aptoide exact-version node rejected: requested '${version#v}', advertised '${actual:-none}'"
		return 1
	}
	url=$(jq -r '.url // .urlAlt // empty' <<<"$selected")
	format=$(jq -r '.format // "APK"' <<<"$selected")
	if [ "$format" != APK ]; then
		npr "Aptoide exact-version '$version' is AAB-backed; dynamic split acquisition is not enabled yet"
		return 1
	fi
	[ -n "$url" ] || return 1
	pr "Downloading Aptoide exact-version variant: version='${version#v}', arch='$arch'"
	req "$url" "$output" || return 1
	if ! validate_standalone_derivation "$output" "$arch"; then
		rm -f "$output"
		return 1
	fi
	jq -c --arg source aptoide '. + {schemaVersion:1,source:$source}' <<<"$selected" >"${output}.source.json"
}

# -------------------- APKPure history API + EFF apkeep fallback --------------------
apkpure_history_request() {
	local pkg=$1 endpoint
	endpoint="https://tapi.pureapk.com/v3/get_app_his_version?package_name=${pkg}&hl=en"
	req "$endpoint" - \
		-H 'Accept: application/json' \
		-H 'Ual-Access-Businessid: projecta' \
		-H 'Ual-Access-ProjectA: {"device_info":{"os_ver":"35"}}'
}

apkeep_arches_for_shared() {
	local arches_json=$1 arch abi
	local values=()
	while IFS= read -r arch; do
		[ -n "$arch" ] || continue
		if [ "$arch" = universal ]; then
			values+=(arm64-v8a armeabi-v7a x86_64 x86)
		elif abi=$(android_abi_for_build_arch "$arch"); then
			values+=("$abi")
		fi
	done < <(jq -r '.[] | if type == "string" then . else .arch end' <<<"$arches_json")
	printf '%s\n' "${values[@]}" | awk 'NF && !seen[$0]++' | paste -sd';'
}

apkeep_download_candidate() {
	local pkg=$1 version=$2 arch_option=$3 out_dir=$4
	local selector="${pkg}@${version}" synthetic
	local cmd candidates=()
	ensure_apkeep || return 1
	mkdir -p "$out_dir"
	cmd=("$APKEEP" -a "$selector" -d apk-pure)
	[ -z "$arch_option" ] || cmd+=(-o "arch=${arch_option}")
	if ! "${cmd[@]}" "$out_dir" >&2; then
		npr "APKPure/apkeep exact-version node failed: package='$pkg' version='$version' arches='${arch_option:-default}'"
		return 1
	fi
	mapfile -d '' candidates < <(find "$out_dir" -type f \( -iname '*.apk' -o -iname '*.xapk' -o -iname '*.apkm' -o -iname '*.apks' \) -print0)
	if [ "${#candidates[@]}" -eq 1 ]; then
		printf '%s\n' "${candidates[0]}"
		return 0
	fi
	# Some downloader/source combinations materialize a split set as individual
	# APKs. Preserve it as a normal split container so the existing selector and
	# signature gates handle it identically to APKM/APKS/XAPK inputs.
	if [ "${#candidates[@]}" -gt 1 ]; then
		local file
		for file in "${candidates[@]}"; do
			if [[ ${file,,} != *.apk ]]; then
				npr "APKPure/apkeep returned mixed container payloads for '$pkg' '$version'; refusing ambiguous candidate set"
				return 1
			fi
		done
		synthetic="$out_dir/apkeep-splits.apks"
		zip -q -j "$synthetic" "${candidates[@]}" || return 1
		printf '%s\n' "$synthetic"
		return 0
	fi
	npr "APKPure/apkeep produced no APK payload candidate for '$pkg' '$version' arches='${arch_option:-default}'"
	return 1
}

get_apkpure_resp() {
	__APKPURE_PKG_NAME__=$1
	__APKPURE_RESP__=""
	if response=$(apkpure_history_request "$1" 2>/dev/null) && \
	   jq -e '.version_list | type == "array" and length > 0' >/dev/null <<<"$response"; then
		__APKPURE_RESP__=$response
		return 0
	fi
	# Preserve the pinned apkeep transport as a fallback when the API is blocked
	# or changes shape. Discovery remains available rather than making one
	# reverse-engineered metadata endpoint a single point of failure.
	ensure_apkeep || return 1
}
get_apkpure_pkg_name() { echo "$__APKPURE_PKG_NAME__"; }
get_apkpure_vers() {
	local output
	if [ -n "${__APKPURE_RESP__:-}" ]; then
		python3 "$CWD/scripts/apkpure_inventory.py" versions --json - <<<"$__APKPURE_RESP__"
		return
	fi
	ensure_apkeep || return 1
	output=$("$APKEEP" -l -a "$__APKPURE_PKG_NAME__" -d apk-pure 2>/dev/null) || return 1
	# apkeep's list output is deliberately treated as presentation text. Extract
	# version-like tokens rather than depending on an undocumented line layout.
	grep -Eo '[0-9]+([.][0-9A-Za-z_-]+)+' <<<"$output" | awk '!seen[$0]++'
}

apkpure_api_download() {
	local version=$1 output=$2 arch=$3 selected url format
	[ -n "${__APKPURE_RESP__:-}" ] || return 1
	selected=$(python3 "$CWD/scripts/apkpure_inventory.py" select --json - --version "$version" --arch "$arch" <<<"$__APKPURE_RESP__") || return 1
	url=$(jq -r '.url // empty' <<<"$selected")
	format=$(jq -r '.format // empty | ascii_downcase' <<<"$selected")
	[ -n "$url" ] || return 1
	pr "Downloading APKPure history API variant: version='${version#v}', arch='$arch', format='${format:-unknown}'"
	case "$format" in
		xapk|apks|apkm)
			download_split_container "$url" "$output" "$arch" || return 1
			;;
		apk)
			req "$url" "$output" || return 1
			if ! validate_standalone_derivation "$output" "$arch"; then
				rm -f "$output"
				return 1
			fi
			;;
		*)
			npr "APKPure history API returned unsupported payload format '$format'"
			return 1
			;;
	esac
	jq -c --arg source apkpure '. + {schemaVersion:1,source:$source}' <<<"$selected" >"${output}.source.json"
}

dl_apkpure() {
	local pkg=$1 version=$2 output=$3 arch=$4 _dpi=$5 arch_option temp candidate
	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "$output" "$arch"
		return $?
	fi
	if apkpure_api_download "$version" "$output" "$arch"; then
		return 0
	fi
	rm -f "$output" "${output}.bundle" "${output}.bundle-selection.json" "${output}.source.json"
	npr "APKPure history API had no usable '$arch' payload for '${version#v}'; falling back to pinned apkeep"
	if [ "$arch" = universal ]; then
		arch_option='arm64-v8a;armeabi-v7a;x86_64;x86'
	else
		arch_option=$(android_abi_for_build_arch "$arch") || return 1
	fi
	temp=$(mktemp -d -p "$TEMP_DIR" apkeep.XXXXXX)
	candidate=$(apkeep_download_candidate "$pkg" "$version" "$arch_option" "$temp") || { rm -rf "$temp"; return 1; }
	if is_split_container "$candidate"; then
		mv -f "$candidate" "${output}.bundle"
		rm -rf "$temp"
		merge_splits "${output}.bundle" "$output" "$arch"
	else
		mv -f "$candidate" "$output"
		rm -rf "$temp"
		validate_standalone_derivation "$output" "$arch"
	fi
}
dl_apkpure_shared() {
	local pkg=$1 version=$2 output=$3 arches_json=$4 _dpi=$5 arch_option temp candidate format
	arch_option=$(apkeep_arches_for_shared "$arches_json")
	[ -n "$arch_option" ] || return 1
	temp=$(mktemp -d -p "$TEMP_DIR" apkeep-shared.XXXXXX)
	candidate=$(apkeep_download_candidate "$pkg" "$version" "$arch_option" "$temp") || { rm -rf "$temp"; return 1; }
	if is_split_container "$candidate"; then format=SPLIT; else format=APK; fi
	mv -f "$candidate" "$output"
	rm -rf "$temp"
	jq -n --arg source apkpure --arg version "$version" --arg arches "$arch_option" --arg format "$format" \
		'{schemaVersion:1,source:$source,version:$version,requestedAbis:($arches|split(";")),format:$format}' >"${output}.source.json"
}

# -------------------- uptodown --------------------
get_uptodown_resp() {
	__UPTODOWN_DLURL__=$1
	__UPTODOWN_RESP__=$(req "${1}/versions" -) || return 1
	__UPTODOWN_RESP_PKG__=
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__"; }
dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	local build_arch=$arch

	local op resp data_code
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")
	local versionURL=""
	local is_bundle=false
	for i in {1..20}; do
		resp=$(req "${uptodown_dlurl}/apps/${data_code}/versions/${i}" -)
		if ! op=$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp"); then
			continue
		fi
		if [ "$(jq -e -r ".kindFile" <<<"$op")" = "xapk" ]; then is_bundle=true; fi
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; else return 1; fi
	done
	if [ -z "$versionURL" ]; then
		npr "Uptodown exact-version node could not find '$version' in the inspected history pages"
		return 1
	fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(req "$versionURL" -) || return 1

	local data_version files node_arch="" data_file_id node_class file_type score format_score
	local best_file_id="" best_file_type="" best_score=-1
	data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ "$data_version" ]; then
		files=$(req "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" - | jq -e -r .content) || return 1
		for ((n = 1; n < 12; n += 1)); do
			node_class=$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || return 1
			if [ "$node_class" != "variant" ]; then
				node_arch=$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			if [ -z "$node_arch" ]; then return 1; fi
			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			if ! score=$(source_artifact_arch_score "$node_arch" "$build_arch" "$file_type"); then continue; fi
			format_score=$(source_format_score "$file_type")
			score=$((score + format_score))
			data_file_id=$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			if [ "$score" -gt "$best_score" ]; then
				best_score=$score
				best_file_id=$data_file_id
				best_file_type=$file_type
			fi
		done
		[ -n "$best_file_id" ] || return 1
		if [ "$best_file_type" = "xapk" ]; then is_bundle=true; else is_bundle=false; fi
		resp=$(req "${uptodown_dlurl}/download/${best_file_id}-x" -)
	fi
	local data_url
	data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp") || return 1
	if [ $is_bundle = true ]; then
		download_split_container "https://dw.uptodown.com/dwn/${data_url}" "$output" "$build_arch"
	else
		req "https://dw.uptodown.com/dwn/${data_url}" "$output"
	fi
}
dl_uptodown_shared() {
	local uptodown_dlurl=$1 version=$2 output=$3 arches_json=$4 _dpi=$5
	local op resp data_code versionURL="" data_version files node_arch="" data_file_id node_class file_type coverage score
	local best_file_id="" best_score=-1
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")
	for i in {1..20}; do
		resp=$(req "${uptodown_dlurl}/apps/${data_code}/versions/${i}" -) || continue
		if ! op=$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp"); then continue; fi
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; fi
	done
	if [ -z "$versionURL" ]; then
		npr "Uptodown exact-version node could not find '$version' in the inspected history pages"
		return 1
	fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(req "$versionURL" -) || return 1
	data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ -n "$data_version" ]; then
		files=$(req "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" - | jq -e -r .content) || return 1
		for ((n = 1; n < 20; n++)); do
			node_class=$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || break
			if [ "$node_class" != variant ]; then
				node_arch=$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			[ -n "$node_arch" ] || continue
			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			[ "${file_type,,}" = xapk ] || continue
			coverage=$(source_arch_coverage_score "$node_arch" "$arches_json") || continue
			score=$((coverage * 10000000))
			data_file_id=$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			if [ "$score" -gt "$best_score" ]; then best_score=$score; best_file_id=$data_file_id; fi
		done
		[ -n "$best_file_id" ] || return 1
		resp=$(req "${uptodown_dlurl}/download/${best_file_id}-x" -) || return 1
	else
		[ "$(jq -r '.kindFile // empty' <<<"$op")" = xapk ] || return 1
	fi
	local data_url
	data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp") || return 1
	[ -n "$data_url" ] || return 1
	req "https://dw.uptodown.com/dwn/${data_url}" "$output" || return 1
	jq -n --arg source uptodown '{schemaVersion:1,source:$source,format:"XAPK"}' >"${output}.source.json"
}

get_uptodown_pkg_name() {
	if [ -z "${__UPTODOWN_RESP_PKG__:-}" ]; then
		[ -n "${__UPTODOWN_DLURL__:-}" ] || return 1
		__UPTODOWN_RESP_PKG__=$(req "${__UPTODOWN_DLURL__}/download" -) || return 1
	fi
	$HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"
}

# -------------------- archive --------------------
archive_select_artifact() {
	local version_f=$1 arch=$2 path descriptor format arch_score format_score score
	local best_path="" best_score=-1
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if [[ ! $path =~ ${version_f}-(all|universal|arm64-v8a|arm-v7a|x86_64|x86)\.(apk|apkm|apks|xapk)$ ]]; then
			continue
		fi
		descriptor=${BASH_REMATCH[1]}
		format=${BASH_REMATCH[2]}
		[ "$descriptor" = all ] && descriptor=universal
		if ! arch_score=$(source_artifact_arch_score "$descriptor" "$arch" "$format"); then continue; fi
		format_score=$(source_format_score "$format")
		score=$((arch_score + format_score))
		if [ "$score" -gt "$best_score" ]; then
			best_score=$score
			best_path=$path
		fi
	done <<<"$__ARCHIVE_RESP__"
	[ -n "$best_path" ] || return 1
	echo "$best_path"
}

archive_select_shared_artifact() {
	local version_f=$1 arches_json=$2 path descriptor format coverage score
	local best_path="" best_score=-1
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if [[ ! $path =~ ${version_f}-(all|universal|arm64-v8a|arm-v7a|x86_64|x86)\.(apkm|apks|xapk)$ ]]; then continue; fi
		descriptor=${BASH_REMATCH[1]}; format=${BASH_REMATCH[2]}
		[ "$descriptor" = all ] && descriptor=universal
		coverage=$(source_arch_coverage_score "$descriptor" "$arches_json") || continue
		score=$((coverage * 10000000 + $(source_format_score "$format")))
		if [ "$score" -gt "$best_score" ]; then best_score=$score; best_path=$path; fi
	done <<<"$__ARCHIVE_RESP__"
	[ -n "$best_path" ] || return 1
	echo "$best_path"
}

dl_archive_shared() {
	local url=$1 version=$2 output=$3 arches_json=$4 _dpi=$5 path version_f=${version// /}
	version_f=${version_f#v}
	path=$(archive_select_shared_artifact "$version_f" "$arches_json") || return 1
	req "${url}/${path}" "$output" || return 1
	jq -n --arg source archive --arg path "$path" '{schemaVersion:1,source:$source,path:$path,format:($path|split(".")[-1]|ascii_upcase)}' >"${output}.source.json"
}

dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path version_f=${version// /}
	version_f=${version_f#v}

	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "$output" "$arch"
		return 0
	fi

	path=$(archive_select_artifact "$version_f" "$arch") || return 1
	if is_split_container "$path"; then
		download_split_container "${url}/${path}" "$output" "$arch"
	else
		req "${url}/${path}" "${output}" || return 1
	fi
}
get_archive_resp() {
	local r
	r=$(req "$1" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_archive_vers() { sed -E 's/^[^-]*-//;s/-(all|universal|arm64-v8a|arm-v7a|x86_64|x86)\.(apk|apkm|apks|xapk)$//' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }

# -------------------- direct --------------------
dl_direct_shared() {
	local url=$1 _version=$2 output=$3 _arches_json=$4 _dpi=$5
	is_split_container "$url" || return 1
	req "$url" "$output" || return 1
	jq -n --arg source direct --arg url "$url" '{schemaVersion:1,source:$source,url:$url,format:($url|split(".")[-1]|ascii_upcase)}' >"${output}.source.json"
}

dl_direct() {
	local url=$1 version=${2// /-} output=$3 arch=$4 _dpi=$5
	if ! grep -q "${version_f#v}-${arch// /}" <<<"$url" \
		&& ! grep -q "${version_f#v}-universal" <<<"$url" \
		&& ! grep -q "${version_f#v}-all" <<<"$url"; then
		epr "Given direct-dlurl for $output is not compatible. Set proper 'arch' and 'version' options."
		return 1
	fi
	if is_split_container "$url"; then
		download_split_container "$url" "$output" "$arch"
	else
		req "$url" "${output}" || return 1
	fi
}
get_direct_vers() { cut -d- -f2 <<<"$__DIRECT_APKNAME__"; }
get_direct_pkg_name() { cut -d- -f1 <<<"$__DIRECT_APKNAME__"; }
get_direct_resp() { __DIRECT_APKNAME__=$(awk -F/ '{print $NF}' <<<"$1"); }
# --------------------------------------------------

source_trust_class() {
	case "$1" in
	direct) echo configured-direct ;;
	aptoide|apkpure|uptodown|apkfab) echo third-party-store ;;
	archive|apkmirror) echo third-party-mirror ;;
	prepared|shared) echo prepared ;;
	*) echo unknown ;;
	esac
}

configured_source_locator() {
	local source_name=$1 key="${1}_dlurl"
	if declare -p args >/dev/null 2>&1; then
		printf '%s\n' "${args[$key]-}"
	else
		printf '\n'
	fi
}

source_provenance_family() {
	case "$1" in
	direct) echo direct ;;
	aptoide) echo aptoide ;;
	apkpure|apkeep) echo apkpure ;;
	uptodown) echo uptodown ;;
	archive) echo internet-archive ;;
	apkmirror) echo apkmirror ;;
	apkfab) echo apkfab ;;
	prepared|shared) echo prepared ;;
	*) echo "$1" ;;
	esac
}

source_provenance_domain() {
	local source_name=$1 locator=${2:-} host=""
	case "$source_name" in
	aptoide) echo aptoide.com; return 0 ;;
	apkpure|apkeep) echo apkpure.com; return 0 ;;
	uptodown) echo uptodown.com; return 0 ;;
	archive) echo archive.org; return 0 ;;
	apkmirror) echo apkmirror.com; return 0 ;;
	apkfab) echo apkfab.com; return 0 ;;
	esac
	if [[ $locator =~ ^https?://([^/:?#]+) ]]; then
		host=${BASH_REMATCH[1],,}
	fi
	case "$host" in
	*.aptoide.com|aptoide.com) echo aptoide.com ;;
	*.apkpure.com|apkpure.com|*.apkpure.net|apkpure.net) echo apkpure.com ;;
	*.uptodown.com|uptodown.com) echo uptodown.com ;;
	*.archive.org|archive.org) echo archive.org ;;
	*.apkmirror.com|apkmirror.com) echo apkmirror.com ;;
	*.apkfab.com|apkfab.com) echo apkfab.com ;;
	*) printf '%s\n' "$host" ;;
	esac
}

sources_share_provenance() {
	local left=$1 left_locator=${2:-} right=$3 right_locator=${4:-}
	local left_family right_family left_domain right_domain
	left_family=$(source_provenance_family "$left")
	right_family=$(source_provenance_family "$right")
	left_domain=$(source_provenance_domain "$left" "$left_locator")
	right_domain=$(source_provenance_domain "$right" "$right_locator")
	if [ -n "$left_domain" ] && [ -n "$right_domain" ] && [ "$left_domain" = "$right_domain" ]; then
		return 0
	fi
	[ -n "$left_family" ] && [ "$left_family" = "$right_family" ]
}

source_requires_signer_pin() {
	case "$1" in
	direct|prepared|shared) return 1 ;;
	*) return 0 ;;
	esac
}

has_upstream_signer_pin() {
	local pkg_name=$1 config=${__TOML__:-'{}'}
	jq -e --arg pkg "$pkg_name" '."upstream-signatures"[$pkg] | type == "array" and length > 0' >/dev/null <<<"$config"
}

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5
	local tmp_files
	tmp_files="$(pwd)/$(mktemp -d -p "$TEMP_DIR")"

	local cmd
	printf -v cmd "java -jar %q patch %q -o %q -p %q --keystore=%q --keystore-entry-password=%q --keystore-password=%q --signer=%q --keystore-entry-alias=%q -t %q" \
		"$cli_jar" "$stock_input" "$patched_apk" "$patches_jar" \
		"$APK_PATCHER_KEYSTORE" "$APK_KEY_PASSWORD" "$APK_KEYSTORE_PASSWORD" \
		"$APK_SIGNER_NAME" "$APK_KEY_ALIAS" "$tmp_files"
	cmd+=" $patcher_args"


	if [ "$OS" = Android ]; then
		local aapt2
		aapt2=$(resolve_aapt2) || { epr "aapt2 is required to patch APKs on Android"; return 1; }
		cmd+=" --custom-aapt2-binary='${aapt2}'"
	fi
	pr "Patching $(basename "$stock_input") with the configured package identity"
	if eval "$cmd"; then [ -f "$patched_apk" ]; else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2 source_name=${3:-${CURRENT_STOCK_SOURCE:-unknown}}
	local sig normalized config=${__TOML__:-'{}'} trust
	trust=$(source_trust_class "$source_name")
	if source_requires_signer_pin "$source_name" && ! has_upstream_signer_pin "$pkg_name"; then
		epr "Refusing unpinned stock from '$source_name' ($trust) for '$pkg_name'"
		return 2
	fi
	if has_upstream_signer_pin "$pkg_name"; then
		sig=$(run_apksigner verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}') || return 1
		[ -n "$sig" ] || return 1
		normalized=$(tr '[:upper:]' '[:lower:]' <<<"$sig")
		echo "$pkg_name signature ($source_name/$trust): ${sig}"
		jq -e --arg pkg "$pkg_name" --arg sig "$normalized" \
			'."upstream-signatures"[$pkg] | map(ascii_downcase) | index($sig) != null' \
			>/dev/null <<<"$config"
	fi
}

stock_security_fingerprint() {
	local apk=$1 output=$2 aapt2="" indicator
	local cmd=(python3 "$CWD/scripts/stock_fingerprint.py" --apk "$apk" --output "$output")
	if aapt2=$(resolve_aapt2 2>/dev/null); then cmd+=(--aapt2 "$aapt2"); fi
	while IFS= read -r indicator; do
		[ -n "$indicator" ] && cmd+=(--indicator "$indicator")
	done < <(jq -r '."stock-security"."deny-indicators"[]? // empty' <<<"${__TOML__:-'{}'}")
	"${cmd[@]}"
}

verify_stock_artifact_signature() {
	local stock_apk=$1 pkg_name=$2 source_name=$3 arch=$4 sig_op split_dir
	if [ -f "${stock_apk}.bundle" ]; then
		split_dir=$(mktemp -d -p "$TEMP_DIR" sig-splits.XXXXXX)
		if ! select_bundle_splits "${stock_apk}.bundle" "$arch" "$split_dir"; then
			rm -rf "$split_dir"
			return 1
		fi
		while IFS= read -r -d '' split_apk; do
			if ! sig_op=$(check_sig "$split_apk" "$pkg_name" "$source_name" 2>&1); then
				epr "Stock split signature mismatch from '$source_name' '$split_apk': $sig_op"
				rm -rf "$split_dir"
				return 1
			fi
		done < <(find "$split_dir" -type f -name '*.apk' -print0)
		rm -rf "$split_dir"
		return 0
	fi
	if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" "$source_name" 2>&1); then
		epr "Stock signature mismatch from '$source_name' '$stock_apk': $sig_op"
		return 1
	fi
}

source_needs_cross_source_verification() {
	source_requires_signer_pin "$1"
}

annotate_cross_source_verification() {
	local security_file=$1 status=$2 source_name=${3:-} digest=${4:-} family=${5:-} domain=${6:-}
	jq --arg status "$status" --arg source "$source_name" --arg digest "$digest" --arg family "$family" --arg domain "$domain" \
		'.crossSource = {status:$status}
		 + (if $source != "" then {source:$source} else {} end)
		 + (if $digest != "" then {comparisonSha256:$digest} else {} end)
		 + (if $family != "" then {provenanceFamily:$family} else {} end)
		 + (if $domain != "" then {provenanceDomain:$domain} else {} end)' \
		"$security_file" >"${security_file}.tmp" && mv -f "${security_file}.tmp" "$security_file"
}

stock_packaging_class() {
	case "${1^^}" in
	APK|STANDALONE) printf '%s\n' standalone ;;
	*) printf '%s\n' split ;;
	esac
}

corroborate_stock_source() {
	local primary_source=$1 primary_apk=$2 primary_security=$3 pkg_name=$4 version=$5 arch=$6 dpi=$7 get_latest=${8:-false}
	local primary_format=${9:-} primary_class primary_digest primary_url candidate source_url temp candidate_apk candidate_digest rc candidate_family candidate_domain candidate_format candidate_class
	local incomparable_source="" incomparable_digest="" incomparable_family="" incomparable_domain=""
	if [ -z "$primary_format" ]; then
		if [ -f "${primary_apk}.bundle" ]; then primary_format=BUNDLE; else primary_format=APK; fi
	fi
	primary_class=$(stock_packaging_class "$primary_format")
	primary_digest=$(jq -r '.comparisonSha256 // empty' "$primary_security")
	[ -n "$primary_digest" ] || return 1
	primary_url=$(configured_source_locator "$primary_source")
	if [ "$(jq -r '."stock-security"."cross-source-verification" // "opportunistic"' <<<"${__TOML__:-'{}'}")" = off ]; then
		annotate_cross_source_verification "$primary_security" disabled
		return 0
	fi
	if ! source_needs_cross_source_verification "$primary_source"; then
		annotate_cross_source_verification "$primary_security" not-required
		return 0
	fi
	local corroboration_sources=()
	if [ -n "${SOURCE_ACQUISITION_GRAPH:-}" ] && [ -f "${SOURCE_ACQUISITION_GRAPH:-}" ]; then
		mapfile -t corroboration_sources < <(source_graph_sources "$SOURCE_ACQUISITION_GRAPH" "$version" branch)
	else
		corroboration_sources=("${DL_SRCS[@]}")
	fi
	for candidate in "${corroboration_sources[@]}"; do
		[ "$candidate" != "$primary_source" ] || continue
		source_url=${args[${candidate}_dlurl]-}
		[ -n "$source_url" ] || continue
		if sources_share_provenance "$primary_source" "$primary_url" "$candidate" "$source_url"; then
			npr "Skipping cross-check source '$candidate' because it shares provenance with '$primary_source'"
			continue
		fi
		declare -F "get_${candidate}_resp" >/dev/null || continue
		declare -F "dl_${candidate}" >/dev/null || continue
		pr "Cross-checking '$primary_source' stock against independent source '$candidate'"
		if ! REQUEST_FAILURE_LEVEL=notice "get_${candidate}_resp" "$source_url"; then
			npr "Cross-check source '$candidate' could not be queried"
			continue
		fi
		temp=$(mktemp -d -p "$TEMP_DIR" corroborate.XXXXXX)
		candidate_apk="$temp/candidate.apk"
		if ! REQUEST_FAILURE_LEVEL=notice "dl_${candidate}" "$source_url" "$version" "$candidate_apk" "$arch" "$dpi" "$get_latest"; then
			rm -rf "$temp"
			continue
		fi
		if ! validate_optional_auto_abi "$candidate_apk" "$arch" false; then
			rm -rf "$temp"
			continue
		fi
		if ! verify_stock_artifact_signature "$candidate_apk" "$pkg_name" "$candidate" "$arch"; then
			rm -rf "$temp"
			continue
		fi
		rc=0
		verify_stock_security "$candidate_apk" "$pkg_name" "$version" "$candidate" "$temp/security.json" || rc=$?
		if [ "$rc" -ne 0 ]; then
			rm -rf "$temp"
			continue
		fi
		candidate_digest=$(jq -r '.comparisonSha256 // empty' "$temp/security.json")
		candidate_family=$(jq -r '.sourceProvenanceFamily // empty' "$temp/security.json")
		candidate_domain=$(jq -r '.sourceProvenanceDomain // empty' "$temp/security.json")
		if [ -f "${candidate_apk}.bundle" ]; then candidate_format=BUNDLE; else candidate_format=APK; fi
		candidate_class=$(stock_packaging_class "$candidate_format")
		rm -rf "$temp"
		# A monolithic APK and an app-bundle split set can be signed by the same
		# upstream key and carry the same package/version while having inherently
		# different DEX/resource/native layouts after merge. Exact content quorum
		# is meaningful only within the same packaging class. The signature gate
		# above remains mandatory for both forms.
		if [ "$candidate_class" != "$primary_class" ]; then
			incomparable_source=$candidate
			incomparable_digest=$candidate_digest
			incomparable_family=$candidate_family
			incomparable_domain=$candidate_domain
			npr "Cross-check source '$candidate' uses $candidate_class packaging while '$primary_source' uses $primary_class; content fingerprint quorum is not comparable"
			continue
		fi
		if [ -n "$candidate_digest" ] && [ "${candidate_digest^^}" = "${primary_digest^^}" ]; then
			annotate_cross_source_verification "$primary_security" matched "$candidate" "$candidate_digest" "$candidate_family" "$candidate_domain"
			pr "Cross-source stock fingerprint matched '$candidate'"
			return 0
		fi
		annotate_cross_source_verification "$primary_security" mismatch "$candidate" "$candidate_digest" "$candidate_family" "$candidate_domain"
		epr "Cross-source stock fingerprint disagreement: '$primary_source' != '$candidate' for $pkg_name $version $arch"
		return 20
	done
	if [ -n "$incomparable_source" ]; then
		annotate_cross_source_verification "$primary_security" incomparable "$incomparable_source" "$incomparable_digest" "$incomparable_family" "$incomparable_domain"
		npr "Independent source '$incomparable_source' passed signer/package/version validation but uses a different packaging class; relying on the pinned signer and local security fingerprint"
		return 0
	fi
	annotate_cross_source_verification "$primary_security" unavailable
	npr "No independent source was available to corroborate '$primary_source'; relying on the pinned signer and local security fingerprint"
	return 0
}

verify_stock_security() {
	local apk=$1 pkg_name=$2 version=$3 source_name=${4:-${CURRENT_STOCK_SOURCE:-unknown}}
	local output=${5:-"${apk}.security.json"} digest actual_pkg actual_version matches trust locator provenance_family provenance_domain
	digest=$(sha256sum "$apk" | awk '{print tolower($1)}') || return 1
	if jq -e --arg digest "$digest" '."stock-security"."deny-sha256" // [] | map(ascii_downcase) | index($digest) != null' \
		>/dev/null <<<"${__TOML__:-'{}'}"; then
		epr "Quarantining known-bad stock artifact from '$source_name': SHA-256 $digest"
		return 3
	fi
	stock_security_fingerprint "$apk" "$output" || return 1
	matches=$(jq -r '.indicatorMatches | length' "$output")
	if [ "$matches" -gt 0 ]; then
		epr "Quarantining stock artifact from '$source_name': configured security indicator matched ($(jq -c '.indicatorMatches' "$output"))"
		return 3
	fi
	actual_pkg=$(jq -r '.packageName // empty' "$output")
	actual_version=$(jq -r '.versionName // empty' "$output")
	if source_requires_signer_pin "$source_name" && { [ -z "$actual_pkg" ] || [ -z "$actual_version" ]; }; then
		epr "Quarantining third-party stock from '$source_name': aapt2 package/version inspection was unavailable"
		return 3
	fi
	if [ -n "$actual_pkg" ] && [ "$actual_pkg" != "$pkg_name" ]; then
		epr "Quarantining stock artifact from '$source_name': package mismatch, expected '$pkg_name', got '$actual_pkg'"
		return 3
	fi
	if [ -n "$actual_version" ] && [ "${actual_version#v}" != "${version#v}" ]; then
		epr "Quarantining stock artifact from '$source_name': version mismatch, expected '$version', got '$actual_version'"
		return 3
	fi
	trust=$(source_trust_class "$source_name")
	locator=$(configured_source_locator "$source_name")
	provenance_family=$(source_provenance_family "$source_name")
	provenance_domain=$(source_provenance_domain "$source_name" "$locator")
	jq --arg source "$source_name" --arg trustClass "$trust" --arg provenanceFamily "$provenance_family" --arg provenanceDomain "$provenance_domain" \
		'. + {source:$source,trustClass:$trustClass,sourceProvenanceFamily:$provenanceFamily,securityValidated:true}
		 + (if $provenanceDomain != "" then {sourceProvenanceDomain:$provenanceDomain} else {} end)' \
		"$output" >"${output}.tmp" && mv -f "${output}.tmp" "$output"
}

prepare_stock_apk_for_build() {
	local stock_apk=$1 output=$2 build_mode=$3 arch=$4
	cp -f "$stock_apk" "$output"
	if [ "$build_mode" = module ]; then
		zip -d "$output" "lib/*" >/dev/null 2>&1 || :
		return 0
	fi
	case "$arch" in
	arm64-v8a)
		zip -d "$output" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
		;;
	arm-v7a)
		zip -d "$output" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
		;;
	x86)
		zip -d "$output" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
		;;
	x86_64)
		zip -d "$output" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
		;;
	universal)
		: # Keep every ABI payload in the universal fallback.
		;;
	*)
		epr "Unsupported build architecture '$arch'"
		return 1
		;;
	esac
}

build_app() {
	eval "declare -A args=${1#*=}"
	local version="" pkg_name=""
	local cli_jar=${args[cli]} patches_file=${args[ptjar]}
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"

	local p_patcher_args=()
	if [ "${args[excluded_patches]}" ]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
	if [ "${args[included_patches]}" ]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	local tried_dl=()
	if [ "${args[pkg_name]}" ]; then
		pkg_name="${args[pkg_name]}"
	else
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			if ! REQUEST_FAILURE_LEVEL=notice get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
				args[${dl_p}_dlurl]=""
				npr "Could not find ${table} in ${dl_p}; trying the next source"
				continue
			fi
			tried_dl+=("$dl_p")
			dl_from=$dl_p
			break
		done
	fi

	if [ -z "$pkg_name" ]; then
		epr "empty pkg name, not building ${table}."
		return 0
	fi
	pr "Package name of '${table}' is '$pkg_name'"
	local list_patches=""
	local get_latest_ver=false
	if [ "${BUILD_STOCK_ONLY:-false}" = true ] || [ "${BUILD_SOURCE_ONLY:-false}" = true ] || [ "${BUILD_PACKAGE_ONLY:-false}" = true ]; then
		if isoneof "$version_mode" auto latest beta; then
			epr "Stock/source/package-only builds require a concrete BUILD_VERSION, got '$version_mode'"
			return 0
		fi
		version=$version_mode
	else
		list_patches=$(patches_list "$cli_jar" "$patches_file" "$pkg_name") || return 1
		if [ "$version_mode" = auto ]; then
			if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
				"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}"); then
				epr "get_patch_last_supported_ver failed '$list_patches'"
				return
			elif [ -z "$version" ]; then get_latest_ver=true; fi
		elif isoneof "$version_mode" latest beta; then
			get_latest_ver=true
			p_patcher_args+=("-f")
		else
			version=$version_mode
			p_patcher_args+=("-f")
		fi
	fi
	if [ $get_latest_ver = true ]; then
		if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
		local pkgvers="" latest_source=""
		for dl_p in "${DL_SRCS[@]}"; do
			[ -n "${args[${dl_p}_dlurl]-}" ] || continue
			if ! isoneof "$dl_p" "${tried_dl[@]}"; then
				if ! REQUEST_FAILURE_LEVEL=notice get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					npr "Could not query '${dl_p}' for a current version of '${table}'; trying the next source"
					continue
				fi
				tried_dl+=("$dl_p")
			fi
			pkgvers=$(get_${dl_p}_vers 2>/dev/null || :)
			[ -n "$pkgvers" ] || continue
			if version=$(get_highest_ver <<<"$pkgvers") && [ -n "$version" ]; then
				latest_source=$dl_p
			else
				version=$(head -1 <<<"$pkgvers")
				[ -n "$version" ] && latest_source=$dl_p
			fi
			[ -n "$latest_source" ] && break
		done
		if [ -n "$latest_source" ]; then
			dl_from=$latest_source
			pr "Discovered version '${version}' from '${latest_source}'"
		fi
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 0
	fi

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	fi

	pr "Choosing version '${version}' for ${table}"
	if [ "${BUILD_SOURCE_ONLY:-false}" = true ]; then
		local source_arches_json=${BUILD_SOURCE_ARCHES_JSON:-'[]'}
		if ! jq -e 'type == "array" and length > 0' >/dev/null <<<"$source_arches_json"; then
			epr "BUILD_SOURCE_ARCHES_JSON must contain at least one architecture branch"
			return 0
		fi
		local source_versions_json=${BUILD_SOURCE_VERSIONS_JSON:-}
		if [ -z "$source_versions_json" ]; then source_versions_json=$(jq -cn --arg version "$version" '[ $version ]'); fi
		if [ "${BUILD_SOURCE_DISCOVERY_ONLY:-false}" = true ]; then
			discover_stock_source_candidates "$pkg_name" "$source_arches_json" "$source_versions_json" "${BUILD_FORWARD_COMPATIBILITY_PROBES:-0}"
		else
			prepare_stock_source_candidates "$pkg_name" "${args[dpi]}" "$source_arches_json" "$source_versions_json"
		fi
		return $?
	fi
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ -n "${BUILD_STOCK_DIR:-}" ]; then
		local stock_import_rc=0
		import_stock_result "$stock_apk" || stock_import_rc=$?
		case "$stock_import_rc" in
		0) pr "Using prepared stock artifact for '${table}'" ;;
		10) return 0 ;;
		*) return 0 ;;
		esac
	fi
	if [ ! -f "$stock_apk" ] && [ -n "${BUILD_STOCK_SOURCE_DIR:-}" ]; then
		local shared_source_rc=0
		try_shared_stock_source "$stock_apk" "$arch" || shared_source_rc=$?
		if [ "$shared_source_rc" -eq 11 ]; then
			local source_reason=${SHARED_SOURCE_UNAVAILABLE_REASON:-"Prepared source branch is unavailable for $arch"}
			if ! record_optional_variant_skip "$source_reason"; then epr "$source_reason"; fi
			return 0
		elif [ "$shared_source_rc" -ne 0 ] && [ "$shared_source_rc" -ne 10 ]; then
			epr "Could not materialize prepared stock source for '$arch'"
			return 0
		fi
	fi
	if [ ! -f "$stock_apk" ] && [ "${BUILD_STOCK_OFFLINE:-false}" = true ]; then
		local source_reason=${SHARED_SOURCE_UNAVAILABLE_REASON:-"Source stage produced no usable payload for ${pkg_name} ${version} ${arch}"}
		if ! record_optional_variant_skip "$source_reason"; then epr "$source_reason"; fi
		return 0
	fi
	if [ ! -f "$stock_apk" ]; then
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			pr "Downloading '${table}' from '${dl_p}'"
			if ! isoneof $dl_p "${tried_dl[@]}"; then
				if ! REQUEST_FAILURE_LEVEL=notice get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					npr "Could not get '${table}' from '${dl_p}'; trying the next source"
					continue
				fi
			fi
			if ! REQUEST_FAILURE_LEVEL=notice dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				npr "Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'; trying the next source"
				continue
			fi
			if ! validate_optional_auto_abi "$stock_apk" "$arch" false; then
				npr "Downloaded '${dl_p}' stock does not provide a meaningful '${arch}' variant; trying the next source"
				rm -f "$stock_apk" "${stock_apk}.bundle" "${stock_apk}.bundle-selection.json"
				continue
			fi
			CURRENT_STOCK_SOURCE=$dl_p
			CURRENT_STOCK_TRUST_CLASS=$(source_trust_class "$dl_p")
			if ! verify_stock_artifact_signature "$stock_apk" "$pkg_name" "$dl_p" "$arch"; then
				npr "Downloaded '${dl_p}' stock failed pinned signature verification; trying the next source"
				rm -f "$stock_apk" "${stock_apk}.bundle" "${stock_apk}.bundle-selection.json" "${stock_apk}.security.json"
				continue
			fi
			if ! verify_stock_security "$stock_apk" "$pkg_name" "$version" "$dl_p" "${stock_apk}.security.json"; then
				npr "Downloaded '${dl_p}' stock failed security validation; trying the next source"
				rm -f "$stock_apk" "${stock_apk}.bundle" "${stock_apk}.bundle-selection.json" "${stock_apk}.security.json"
				continue
			fi
			break
		done
		if [ ! -f "$stock_apk" ]; then
			local unavailable_reason="${OPTIONAL_ABI_UNAVAILABLE_REASON:-No configured stock source could produce ${arch} for ${pkg_name} ${version}}"
			if ! record_optional_variant_skip "$unavailable_reason"; then
				epr "Stock apk not found ($stock_apk): $unavailable_reason"
			fi
			return 0
		fi
	fi
	if ! validate_optional_auto_abi "$stock_apk" "$arch"; then
		return 0
	fi

	local sig_op
	if [ "${PREPARED_STOCK_VERIFIED:-false}" = true ]; then
		pr "Prepared stock validation was completed by the stock stage"
	elif [ -f "${stock_apk}.bundle" ]; then
		rm -rf "${stock_apk}-splits" || :
		if ! select_bundle_splits "${stock_apk}.bundle" "$arch" "${stock_apk}-splits"; then
			epr "Not building $table, the downloaded split container cannot produce '$arch'"
			record_optional_variant_skip "The selected stock bundle cannot produce ${arch} for ${pkg_name} ${version}" || :
			return 0
		fi
		for a in "${stock_apk}"-splits/*.apk; do
			if ! sig_op=$(check_sig "$a" "$pkg_name" "${CURRENT_STOCK_SOURCE:-prepared}" 2>&1); then
				epr "Not building $table, apk signature mismatch '$a': $sig_op"
				rm -rf "${stock_apk}-splits" || :
				return 0
			fi
		done
		rm -rf "${stock_apk}-splits" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" "${CURRENT_STOCK_SOURCE:-prepared}" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 0
		fi
	fi
	if [ ! -f "${stock_apk}.security.json" ]; then
		if ! verify_stock_security "$stock_apk" "$pkg_name" "$version" "${CURRENT_STOCK_SOURCE:-prepared}" "${stock_apk}.security.json"; then
			epr "Not building $table, stock security validation failed"
			return 0
		fi
	fi
	if ! jq -e '.crossSource.status? | type == "string"' "${stock_apk}.security.json" >/dev/null 2>&1; then
		if [ -n "${BUILD_STOCK_SOURCE_DIR:-}" ]; then
			if ! inherit_prepared_source_verification "${stock_apk}.security.json"; then
				epr "Prepared source is missing acquisition-time provenance verification"
				return 0
			fi
		elif [ "${BUILD_STOCK_OFFLINE:-false}" = true ]; then
			epr "Offline stock materialization cannot perform network provenance verification"
			return 0
		else
			local corroboration_rc=0
			corroborate_stock_source "${CURRENT_STOCK_SOURCE:-prepared}" "$stock_apk" "${stock_apk}.security.json" "$pkg_name" "$version" "$arch" "${args[dpi]}" "$get_latest_ver" || corroboration_rc=$?
			if [ "$corroboration_rc" -eq 20 ]; then
				epr "Not building $table, independent stock sources disagree; quarantining this stock candidate"
				return 0
			elif [ "$corroboration_rc" -ne 0 ]; then
				epr "Not building $table, cross-source verification failed unexpectedly"
				return 0
			fi
		fi
	fi
	if [ "${BUILD_STOCK_ONLY:-false}" = true ]; then
		if ! export_stock_result "$stock_apk" "$pkg_name" "$version" "$arch" "${args[include_stock]}"; then
			epr "Could not export prepared stock for '$table'"
			return 0
		fi
		pr "Prepared reusable stock for '${table}'"
		if [ -n "${SHARED_SOURCE_SELECTED_SPLITS_DIR:-}" ]; then
			rm -rf "$SHARED_SOURCE_SELECTED_SPLITS_DIR"
			SHARED_SOURCE_SELECTED_SPLITS_DIR=""
		fi
		return 0
	fi

	log "${table}: ${version}"
	log "  - Patch bundle: ${args[patch_brand]} (${args[patches_src]})"

	local microg_patch="" package_name_patch="" auxiliary_package_name_patch="" auxiliary_list_patches=""
	if [ "${BUILD_PACKAGE_ONLY:-false}" != true ]; then
		microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
		package_name_patch=$(find_package_identity_patch "$list_patches" || :)
		if [ -n "${args[package_identity]}" ] && [ "${args[package_identity]}" != "$pkg_name" ] && \
			[ -z "$package_name_patch" ] && [ -n "${args[identity_ptjar]}" ]; then
			auxiliary_list_patches=$(patches_list "${args[identity_cli]}" "${args[identity_ptjar]}" "$pkg_name") || return 1
			auxiliary_package_name_patch=$(find_package_identity_patch "$auxiliary_list_patches" || :)
			if [ -z "$auxiliary_package_name_patch" ]; then
				epr "Auxiliary identity patch bundle '${args[identity_patches_src]}' has no universal Clone app/package-name patch"
				return 0
			fi
			log "  - Identity patch bundle: ${args[identity_patches_src]} (${auxiliary_package_name_patch})"
		fi
		if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} =~ $microg_patch ]]; then
			wpr "You cant include/exclude microg patch as the builder manages it automatically."
			remove_managed_patch_selection p_patcher_args "$microg_patch"
		fi
		if [ -n "${args[package_identity]}" ] && [ -n "$package_name_patch" ] && [[ ${p_patcher_args[*]} =~ $package_name_patch ]]; then
			wpr "You cannot include/exclude the package-name patch for a target managed by config.toml."
			remove_managed_patch_selection p_patcher_args "$package_name_patch"
		fi
	fi

	local patcher_args patched_apk build_mode
	local patch_brand_f=${args[patch_brand],,}
	patch_brand_f=${patch_brand_f// /-}
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ "${BUILD_PACKAGE_ONLY:-false}" != true ]; then
			local primary_package_identity="${args[package_identity]}"
			if [ -n "$auxiliary_package_name_patch" ]; then primary_package_identity=""; fi
			if ! configure_nonroot_app_identity "$build_mode" "$package_name_patch" "$primary_package_identity" "$pkg_name" "${args[patcher_args]}" patcher_args; then
				epr "Skipping '${table}' non-root APK because its stable package identity could not be applied"
				continue
			fi
		fi
		if [ -n "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${patch_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${patch_brand_f}-${version_f}-${arch_f}.apk"
		fi
		if [ -n "$microg_patch" ]; then
			if [ "$build_mode" = apk ]; then
				patcher_args+=("-e \"${microg_patch}\"")
			elif [ "$build_mode" = module ]; then
				patcher_args+=("-d \"${microg_patch}\"")
			fi
		fi

		local stock_apk_to_patch="${stock_apk}.stripped.apk"
		if [ "${BUILD_PACKAGE_ONLY:-false}" != true ]; then
			if ! prepare_stock_apk_for_build "$stock_apk" "$stock_apk_to_patch" "$build_mode" "$arch"; then
				epr "Could not prepare stock APK for '$arch'"
				return 0
			fi
		fi

		local apk_output="${BUILD_DIR}/${app_name_l}-${patch_brand_f}-v${version_f}-${arch_f}.apk"
		local patch_imported=false patch_import_rc=0 auxiliary_notice_source="" imported_patches_version=""
		if [ -n "${BUILD_PATCH_DIR:-}" ]; then
			import_patch_result "$patched_apk" "$pkg_name" "$version" "$arch" "$build_mode" "${args[patches_src]}" || patch_import_rc=$?
			if [ "$patch_import_rc" -ne 0 ]; then
				rm -f "$stock_apk_to_patch" "$patched_apk"
				epr "Could not import prepared patch artifact for '${table}'"
				return 0
			fi
			patch_imported=true
			auxiliary_notice_source=${IMPORTED_PATCH_AUXILIARY_NOTICE_SOURCE:-}
			imported_patches_version=${IMPORTED_PATCHES_VERSION:-}
			pr "Using prepared patch artifact for '${table}'"
		elif [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi
		rm -f "$stock_apk_to_patch"
		if [ "$patch_imported" = false ] && [ "$build_mode" = apk ] && [ -n "$auxiliary_package_name_patch" ]; then
			auxiliary_notice_source=${args[identity_patches_src]}
			local identity_apk="${patched_apk}.identity.apk"
			if ! apply_auxiliary_package_identity "$patched_apk" "$identity_apk" "${args[package_identity]}" \
				"$auxiliary_package_name_patch" "${args[identity_cli]}" "${args[identity_ptjar]}"; then
				rm -f "$identity_apk" "$apk_output"
				epr "Discarding '${table}' because the auxiliary package identity patch failed"
				continue
			fi
			mv -f "$identity_apk" "$patched_apk"
		fi
		if [ "${BUILD_PATCH_ONLY:-false}" = true ]; then
			local exported_patches_version
			exported_patches_version=$(basename "$patches_file")
			exported_patches_version=${exported_patches_version%.mpp}
			exported_patches_version=${exported_patches_version#patches-}
			if ! export_patch_result "$patched_apk" "$pkg_name" "$version" "$arch" "$build_mode" "${args[patches_src]}" "$exported_patches_version" "$auxiliary_notice_source"; then
				epr "Could not export prepared patch artifact for '${table}'"
				return 0
			fi
			pr "Prepared reusable patch output for '${table}'"
			return 0
		fi
		if [ -n "${args[launcher_name]}" ] || [ -n "${args[launcher_icon_overlay]}" ]; then
			local branded_apk="${patched_apk}.branded.apk"
			if ! apply_launcher_branding "$patched_apk" "${args[launcher_name]}" "${args[launcher_icon_overlay]}" "$branded_apk"; then
				rm -f "$branded_apk" "$apk_output"
				epr "Discarding '${table}' because launcher branding failed"
				continue
			fi
			mv -f "$branded_apk" "$patched_apk"
		fi
		if ! embed_patch_notice_in_apk "$patched_apk" "${args[patches_src]}"; then
			rm -f "$patched_apk" "$apk_output"
			epr "Discarding '${table}' because a required patch notice could not be embedded"
			continue
		fi
		if [ "$build_mode" = apk ] && [ -n "$auxiliary_notice_source" ] && \
			! embed_patch_notice_in_apk "$patched_apk" "$auxiliary_notice_source"; then
			rm -f "$patched_apk" "$apk_output"
			epr "Discarding '${table}' because an auxiliary patch notice could not be embedded"
			continue
		fi
		local finalized_apk="${patched_apk}.finalized"
		if ! finalize_apk "$patched_apk" "$finalized_apk"; then
			rm -f "$patched_apk" "$finalized_apk" "$apk_output"
			epr "Discarding '${table}' because APK finalization failed"
			continue
		fi
		mv -f "$finalized_apk" "$patched_apk"
		if [ "$build_mode" = apk ]; then
			if ! verify_apk_package_identity "$patched_apk" "${args[package_identity]}"; then
				rm -f "$patched_apk" "$apk_output"
				epr "Discarding '${table}' non-root APK with an unexpected package identity"
				continue
			fi
			if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
				mv -f "$patched_apk" "$apk_output"
			else
				cp -f "$patched_apk" "$apk_output"
			fi
			pr "Built ${table} (non-root): '${apk_output}'"
			if [ -n "${args[package_identity]}" ]; then
				log "  - Stable non-root package: ${args[package_identity]}"
			fi
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj="${table,,}-update.json"

		module_config "$base_template" "$pkg_name" "$version" "$arch"

		local patches_version=$imported_patches_version
		if [ -z "$patches_version" ]; then
			patches_version=$(basename "$patches_file")
			patches_version=${patches_version%.mpp}
			patches_version=${patches_version#patches-}
		fi
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${args[patch_brand]}" \
			"${version} (patches ${patches_version})" \
			"${app_name} ${args[patch_brand]} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-${patch_brand_f}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"
		if ! copy_patch_notice_to_module "${args[patches_src]}" "$base_template"; then
			epr "Discarding '${table}' module because a required patch notice could not be copied"
			rm -rf "$base_template"
			continue
		fi

		if [ "${args[include_stock]}" != "disable" ]; then
			mkdir -p "${base_template}/stock/"
			if [ "${args[include_stock]}" = "merged" ]; then
				cp -f "$stock_apk" "${base_template}/stock/base.apk"
			elif [ "${args[include_stock]}" = "split" ]; then
				if [ -n "${PREPARED_STOCK_SPLITS_DIR:-}" ] && [ -d "$PREPARED_STOCK_SPLITS_DIR" ]; then
					cp -f "$PREPARED_STOCK_SPLITS_DIR"/*.apk "${base_template}/stock/"
				elif [ -f "${stock_apk}.bundle" ]; then
					if ! select_bundle_splits "${stock_apk}.bundle" "$arch" "${base_template}/stock/"; then
						epr "Could not select '$arch' stock splits for $table"
						return 0
					fi
				else
					epr "Cannot include stock splits because $table has no prepared split set"
					return 0
				fi
			fi
		fi

		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .
		popd >/dev/null || :
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

module_config() {
	local ma=""
	case "$4" in
		arm64-v8a) ma="arm64" ;;
		arm-v7a) ma="arm" ;;
		x86_64) ma="x64" ;;
		x86) ma="x86" ;;
		universal) ma="" ;;
		*) return 1 ;;
	esac
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=j-hc
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
