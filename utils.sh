#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("direct" "archive" "apkmirror" "uptodown")
APKEDITOR_VERSION=${APKEDITOR_VERSION:-1.4.9}
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
	for patch_name in "Clone app" "Change package name"; do
		if grep -Fqx "Name: $patch_name" <<<"$list_patches"; then
			printf '%s\n' "$patch_name"
			return 0
		fi
	done
	return 1
}

configure_nonroot_app_identity() {
	local build_mode=$1 package_name_patch=$2 package_identity=$3 user_patcher_args=$4
	local -n output_args=$5
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
		epr "Cannot apply stable package identity '$package_identity': the selected patch bundle lacks a compatible Clone app/package-name patch"
		return 1
	fi
	output_args+=("-e \"${package_name_patch}\"" "-OpackageName=$package_identity")
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
	if ! op=$(java -jar "$APKSIGNER" sign \
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
	if ! op=$(java -jar "$APKSIGNER" verify --verbose --print-certs "$apk" 2>&1); then
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
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}

_clean_tmp() {
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*tmp_* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./*-temporary-files
}

abort() {
	epr "ABORT: ${1-}"
	_clean_tmp
	trap - SIGTERM SIGINT EXIT
	kill -9 -- -$$ 2>/dev/null
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

get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	pr "Getting prebuilts (${patches_src%/*})" >&2
	local cl_dir=${patches_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-patcher
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	for src_ver in "Patches $patches_src $patches_ver" "CLI $cli_src $cli_ver"; do
		set -- $src_ver
		local tag=$1 src=$2 ver=${3-}

		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-patcher
		[ -d "$dir" ] || mkdir "$dir"

		local releases_url="https://api.github.com/repos/${src}/releases" name_ver
		if [ "$ver" = "dev" ]; then
			local resp
			resp=$(gh_req "$releases_url" -) || return 1
			ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
		fi
		if [ "$ver" = "latest" ]; then
			releases_url+="/latest"
			name_ver="*"
		else
			releases_url+="/tags/${ver}"
			name_ver="$ver"
		fi

		local file
		if [ "$tag" = "CLI" ]; then
			file=$(find "$dir" -maxdepth 1 \( -name "*cli-${name_ver#v}*.jar" -o -name "*desktop-${name_ver#v}*.jar" \) -type f 2>/dev/null)
			local grab_cl=false
		elif [ "$tag" = "Patches" ]; then
			file=$(find "$dir" -maxdepth 1 -name "*patches-${name_ver#v}.*" -type f 2>/dev/null)
			local grab_cl=true
		else abort unreachable; fi

		local url tag_name matches
		if [ "$ver" = "latest" ]; then
			file=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" | head -1)
		else
			file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | head -1)
		fi
		if [ -z "$file" ]; then
			local resp asset name
			resp=$(gh_req "$releases_url" -) || return 1
			tag_name=$(jq -r '.tag_name' <<<"$resp") || return 1
			if [ "$tag" = "Patches" ]; then
				matches=$(jq -e '.assets | map(select(.name | endswith(".mpp")))' <<<"$resp") || return 1
			else
				matches=$(jq -e '.assets | map(select(.name | endswith(".jar")))' <<<"$resp") || return 1
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				if [ "$tag" = "CLI" ]; then
					matches_new=$(jq -e 'map(select((.name | endswith("-all.jar")) and (.name | contains("-dev") | not)))' <<<"$matches")
					if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then matches=$matches_new; fi
				fi
				if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
					matches_new=$(jq -e 'map(select(.name | contains("-dev") | not))' <<<"$matches")
					if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then matches=$matches_new; fi
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
				epr "No asset was found"
				return 1
			elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
				wpr "More than 1 asset was found for this release. Falling back to the first one found..."
			fi
			asset=$(jq -r ".[0]" <<<"$matches")
			url=$(jq -r .url <<<"$asset")
			name=$(jq -r .name <<<"$asset")
			file="${dir}/${name}"
			gh_dl "$file" "$url" >&2 || return 1
			echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
		else
			grab_cl=false
			name=$(basename "$file")
			tag_name=$(cut -d'-' -f3- <<<"$name")
			tag_name=v${tag_name%.*}
		fi

		if [ "$tag" = "Patches" ] && [ "$grab_cl" = true ]; then
			echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"
		fi
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
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
		epr "Request failed: $ip"
		if [ "$dlp" != - ]; then rm -f "$dlp"; fi
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
}
req() { _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
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
	local reason=$1
	[ "${BUILD_OPTIONAL_VARIANT:-false}" = true ] || return 1
	mkdir -p "$BUILD_DIR"
	jq -n \
		--arg target "${BUILD_TARGET:-}" \
		--arg arch "${BUILD_ARCH:-}" \
		--arg mode "${BUILD_MODE:-}" \
		--arg reason "$reason" \
		'{schemaVersion:1,target:$target,arch:$arch,mode:$mode,reason:$reason}' \
		>"$BUILD_DIR/skip.json"
	wpr "Optional variant unavailable: $reason"
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

validate_optional_auto_abi() {
	local stock_apk=$1 arch=$2 record=${3:-true} requested available reason
	[ "${BUILD_OPTIONAL_VARIANT:-false}" = true ] || return 0
	[ "$arch" != universal ] || return 0
	requested=$(android_abi_for_build_arch "$arch") || return 2
	if ! available=$(stock_native_abis "$stock_apk"); then
		return 2
	fi
	if [ -z "$available" ]; then
		reason="Stock APK is ABI-independent; universal already covers ${arch}"
	elif ! grep -qx "$requested" <<<"$available"; then
		reason="Stock APK has native ABIs [$(paste -sd, <<<"$available")] but not ${requested}"
	else
		return 0
	fi
	OPTIONAL_ABI_UNAVAILABLE_REASON=$reason
	if [ "$record" = true ]; then record_optional_variant_skip "$reason" || :; fi
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

select_bundle_splits() {
	local bundle=$1 arch=$2 output_dir=$3 manifest=${4-}
	local args=(select --bundle "$bundle" --arch "$arch" --output-dir "$output_dir")
	[ -n "$manifest" ] && args+=(--manifest "$manifest")
	python3 "$CWD/scripts/stock_bundle.py" "${args[@]}" >/dev/null
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
	pr "Merging selected splits"
	gh_dl "$TEMP_DIR/apkeditor.jar" "$APKEDITOR_URL" >/dev/null || { rm -rf "$selected"; return 1; }
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "$selected" -o "${output}-unsigned" -clean-meta -f 2>&1); then
		rm -rf "$selected"
		epr "APKEditor error: $OP"
		return 1
	fi
	rm -rf "$selected"
	# Sign the merged stock APK without exposing passwords in process arguments.
	if ! sign_apk "${output}-unsigned" "$output"; then return 1; fi
	rm -f "${output}-unsigned"
	return 0
}

is_split_container() {
	case "${1##*.}" in
	apkm|apks|xapk) return 0 ;;
	*) return 1 ;;
	esac
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
apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4"
	local dlurl="" node app_table emptyCheck source_arch score
	local best_url="" best_score=-1

	local appdpi=("nodpi" "anydpi")
	if [ "$dpi" ]; then
		appdpi+=($dpi)
	fi

	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ -z "$emptyCheck" ]; then break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" != "$apk_bundle" ]; then continue; fi
		if ! isoneof "$(sed -n 6p <<<"$app_table")" "${appdpi[@]}"; then continue; fi
		source_arch=$(sed -n 4p <<<"$app_table")
		if ! score=$(source_arch_score "$source_arch" "$arch"); then continue; fi
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		if [ "$score" -gt "$best_score" ]; then
			best_score=$score
			best_url=$dlurl
		fi
	done
	[ -n "$best_url" ] || return 1
	echo "$best_url"
}

dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false
	local build_arch=$arch

	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "${output}" "$build_arch"
		return 0
	fi

	local resp node app_table apkmname dlurl=""
	apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
	apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
	url="${url}/${apkmname}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		for type in APK BUNDLE; do
			if dlurl=$(apkmirror_search "$resp" "$dpi" "$build_arch" "$type"); then
				if [ "$type" = "BUNDLE" ]; then
					is_bundle=true
				else is_bundle=false; fi
				break 2
			fi
		done
		if [ -z "$dlurl" ]; then return 1; fi
		resp=$(req "$dlurl" -)
	fi
	url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	url=$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1

	if [ "$is_bundle" = true ]; then
		download_split_container "$url" "$output" "$build_arch"
	else
		req "$url" "${output}" || return 1
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
	__APKMIRROR_RESP__=$(req "${1}" -) || return 1
	__APKMIRROR_CAT__="${1##*/}"
}

# -------------------- uptodown --------------------
get_uptodown_resp() {
	__UPTODOWN_RESP__=$(req "${1}/versions" -) || return 1
	__UPTODOWN_RESP_PKG__=$(req "${1}/download" -) || return 1
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
	if [ -z "$versionURL" ]; then return 1; fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(req "$versionURL" -) || return 1

	local data_version files node_arch="" data_file_id node_class file_type score
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
			if ! score=$(source_arch_score "$node_arch" "$build_arch"); then continue; fi

			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
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
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path version_f=${version// /}
	version_f=${version_f#v}

	if [ -f "${output}.bundle" ]; then
		merge_splits "${output}.bundle" "$output" "$arch"
		return 0
	fi

	path=$(grep -E -m1 "${version_f}-${arch// /}\.(apk|apkm|apks|xapk)$" <<<"$__ARCHIVE_RESP__" || :)
	if [ -z "$path" ] && [ "$arch" = universal ]; then
		# Legacy mirrors commonly call the universal artifact `all`.
		path=$(grep -E -m1 "${version_f}-all\.(apk|apkm|apks|xapk)$" <<<"$__ARCHIVE_RESP__" || :)
	elif [ -z "$path" ]; then
		# A universal APK or split container can be normalized into an ABI-specific stock APK.
		path=$(grep -E -m1 "${version_f}-(universal|all)\.(apk|apkm|apks|xapk)$" <<<"$__ARCHIVE_RESP__" || :)
	fi
	[ -n "$path" ] || return 1
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
	local file=$1 pkg_name=$2
	local sig normalized
	if jq -e --arg pkg "$pkg_name" '."upstream-signatures"[$pkg] | type == "array" and length > 0' >/dev/null <<<"$__TOML__"; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		normalized=$(tr '[:upper:]' '[:lower:]' <<<"$sig")
		echo "$pkg_name signature: ${sig}"
		jq -e --arg pkg "$pkg_name" --arg sig "$normalized" \
			'."upstream-signatures"[$pkg] | map(ascii_downcase) | index($sig) != null' \
			>/dev/null <<<"$__TOML__"
	fi
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
			if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
				args[${dl_p}_dlurl]=""
				epr "ERROR: Could not find ${table} in ${dl_p}"
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
	local list_patches
	list_patches=$(patches_list "$cli_jar" "$patches_file" "$pkg_name") || return 1
	local get_latest_ver=false
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
	if [ $get_latest_ver = true ]; then
		if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
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
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ ! -f "$stock_apk" ]; then
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			pr "Downloading '${table}' from '${dl_p}'"
			if ! isoneof $dl_p "${tried_dl[@]}"; then
				if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					epr "ERROR: Could not get '${table}' from '${dl_p}'"
					continue
				fi
			fi
			if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				epr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi
			if ! validate_optional_auto_abi "$stock_apk" "$arch" false; then
				epr "Downloaded '${dl_p}' stock does not provide a meaningful '${arch}' variant; trying the next source"
				rm -f "$stock_apk" "${stock_apk}.bundle" "${stock_apk}.bundle-selection.json"
				continue
			fi
			break
		done
		if [ ! -f "$stock_apk" ]; then
			epr "Stock apk not found ($stock_apk)"
			record_optional_variant_skip "${OPTIONAL_ABI_UNAVAILABLE_REASON:-No configured stock source could produce ${arch} for ${pkg_name} ${version}}" || :
			return 0
		fi
	fi
	if ! validate_optional_auto_abi "$stock_apk" "$arch"; then
		return 0
	fi

	local sig_op
	if [ -f "${stock_apk}.bundle" ]; then
		rm -rf "${stock_apk}-splits" || :
		if ! select_bundle_splits "${stock_apk}.bundle" "$arch" "${stock_apk}-splits"; then
			epr "Not building $table, the downloaded split container cannot produce '$arch'"
			record_optional_variant_skip "The selected stock bundle cannot produce ${arch} for ${pkg_name} ${version}" || :
			return 0
		fi
		for a in "${stock_apk}"-splits/*.apk; do
			if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
				epr "Not building $table, apk signature mismatch '$a': $sig_op"
				rm -rf "${stock_apk}-splits" || :
				return 0
			fi
		done
		rm -rf "${stock_apk}-splits" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 0
		fi
	fi
	log "${table}: ${version}"
	log "  - Patch bundle: ${args[patch_brand]} (${args[patches_src]})"

	local microg_patch package_name_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
	package_name_patch=$(find_package_identity_patch "$list_patches" || :)
	if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} =~ $microg_patch ]]; then
		wpr "You cant include/exclude microg patch as the builder manages it automatically."
		remove_managed_patch_selection p_patcher_args "$microg_patch"
	fi
	if [ -n "${args[package_identity]}" ] && [ -n "$package_name_patch" ] && [[ ${p_patcher_args[*]} =~ $package_name_patch ]]; then
		wpr "You cannot include/exclude the package-name patch for a target managed by config.toml."
		remove_managed_patch_selection p_patcher_args "$package_name_patch"
	fi

	local patcher_args patched_apk build_mode
	local patch_brand_f=${args[patch_brand],,}
	patch_brand_f=${patch_brand_f// /-}
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if ! configure_nonroot_app_identity "$build_mode" "$package_name_patch" "${args[package_identity]}" "${args[patcher_args]}" patcher_args; then
			epr "Skipping '${table}' non-root APK because its stable package identity could not be applied"
			continue
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
		if ! prepare_stock_apk_for_build "$stock_apk" "$stock_apk_to_patch" "$build_mode" "$arch"; then
			epr "Could not prepare stock APK for '$arch'"
			return 0
		fi

		local apk_output="${BUILD_DIR}/${app_name_l}-${patch_brand_f}-v${version_f}-${arch_f}.apk"
		if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi
		rm "$stock_apk_to_patch"
		if ! embed_patch_notice_in_apk "$patched_apk" "${args[patches_src]}"; then
			rm -f "$patched_apk" "$apk_output"
			epr "Discarding '${table}' because a required patch notice could not be embedded"
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

		local patches_version
		patches_version=$(basename "$patches_file")
		patches_version=${patches_version%.mpp}
		patches_version=${patches_version#patches-}
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
				if [ ! -f "${stock_apk}.bundle" ]; then
					epr "Cannot include stock splits because $table was not acquired from a split container"
					return 0
				fi
				if ! select_bundle_splits "${stock_apk}.bundle" "$arch" "${base_template}/stock/"; then
					epr "Could not select '$arch' stock splits for $table"
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
