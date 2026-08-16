#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

source utils.sh

trap "abort" INT

if [ "${1-}" = "clean" ]; then
	rm -r "$TEMP_DIR" "$BUILD_DIR" build.md
	exit 0
fi

jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"
java --version >/dev/null || abort "\`java\` is not installed. install it with 'apt install openjdk-21-jre' or equivalent"
python3 --version >/dev/null || abort "\`python3\` is not installed. install it with 'apt install python3' or equivalent"
zip --version >/dev/null || abort "\`zip\` is not installed. install it with 'apt install zip' or equivalent"

set_prebuilts

vtf() { if ! isoneof "${1}" "true" "false"; then abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"; fi; }

# -- Main config --
toml_prep "${1:-config.toml}" || abort "could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t=$(toml_get_table_main)
load_app_catalog "${1:-config.toml}"
validate_build_apps
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL="9"
if ! PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs); then
	if [ "$OS" = Android ]; then PARALLEL_JOBS=1; else PARALLEL_JOBS=$(nproc); fi
fi
PARALLEL_JOBS=1 # TODO: multiple jobs were broken by recent cli versions. and i cant bother to fix it so instead, i disable it.
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER="latest"
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version) || DEF_CLI_VER="latest"
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC="MorpheApp/morphe-patches"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source) || DEF_CLI_SRC="MorpheApp/morphe-desktop"
DEF_PATCH_BRAND=$(toml_get "$main_config_t" patch-brand) || DEF_PATCH_BRAND="Morphe"
DEF_ENABLE_APTOIDE=$(toml_get "$main_config_t" enable-aptoide) || DEF_ENABLE_APTOIDE=true
DEF_ENABLE_APKPURE=$(toml_get "$main_config_t" enable-apkpure) || DEF_ENABLE_APKPURE=true
vtf "$DEF_ENABLE_APTOIDE" "enable-aptoide"
vtf "$DEF_ENABLE_APKPURE" "enable-apkpure"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

if [ "${2-}" = "--config-update" ]; then
	config_update
	exit 0
fi

if [ "${BUILD_SOURCE_ONLY:-false}" != true ]; then
	load_package_identity
fi

: >build.md
ENABLE_MODULE_UPDATE=$(toml_get "$main_config_t" enable-module-update) || ENABLE_MODULE_UPDATE=true
if [ "$ENABLE_MODULE_UPDATE" = true ] && [ -z "${GITHUB_REPOSITORY-}" ]; then
	pr "You are building locally. Module updates will not be enabled."
	ENABLE_MODULE_UPDATE=false
fi
if ((COMPRESSION_LEVEL > 9)) || ((COMPRESSION_LEVEL < 0)); then abort "compression-level must be within 0-9"; fi

rm -rf module/bin/*/tmp.*
for file in "$TEMP_DIR"/*/changelog.md; do
	[ -f "$file" ] && : >"$file"
done

if [ "${BUILD_MODE:-}" != "apk" ]; then
	mkdir -p ${MODULE_TEMPLATE_DIR}/bin/arm64 ${MODULE_TEMPLATE_DIR}/bin/arm ${MODULE_TEMPLATE_DIR}/bin/x86 ${MODULE_TEMPLATE_DIR}/bin/x64
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-arm64-v8a"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-armeabi-v7a"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/x86/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/x64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86_64"
fi

idx=0
for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	if [ -n "${BUILD_TARGET:-}" ] && [ "$table_name" != "$BUILD_TARGET" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	vtf "$enabled" "enabled"
	if [ "$enabled" = false ]; then continue; fi
	if ((idx >= PARALLEL_JOBS)); then
		wait -n
		idx=$((idx - 1))
	fi

	declare -A app_args
	patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
	patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
	cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
	cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER
	identity_patches_src=$(toml_get "$t" identity-patches-source) || identity_patches_src=""
	identity_patches_ver=$(toml_get "$t" identity-patches-version) || identity_patches_ver="latest"

	if [ "${BUILD_STOCK_ONLY:-false}" = true ] || [ "${BUILD_SOURCE_ONLY:-false}" = true ]; then
		[ -n "${BUILD_VERSION:-}" ] || abort "BUILD_VERSION is required for a stock/source-only build"
		app_args[cli]=""
		app_args[ptjar]=""
		app_args[identity_cli]=""
		app_args[identity_ptjar]=""
	else
		if ! PREBUILTS="$(get_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")"; then
			epr "Could not get prebuilts"
			continue
		fi
		read -r patches_jar cli_jar <<<"$PREBUILTS"
		app_args[cli]=$cli_jar
		app_args[ptjar]=$patches_jar
		app_args[identity_cli]=""
		app_args[identity_ptjar]=""
		if [ -n "$identity_patches_src" ]; then
			if ! IDENTITY_PREBUILTS="$(get_prebuilts "$cli_src" "$cli_ver" "$identity_patches_src" "$identity_patches_ver")"; then
				epr "Could not get auxiliary identity patch prebuilts"
				continue
			fi
			read -r identity_patches_jar identity_cli_jar <<<"$IDENTITY_PREBUILTS"
			app_args[identity_cli]=$identity_cli_jar
			app_args[identity_ptjar]=$identity_patches_jar
		fi
	fi
	app_args[patch_brand]=$(toml_get "$t" patch-brand) || app_args[patch_brand]=$DEF_PATCH_BRAND
	app_args[patches_src]=$patches_src
	app_args[cli_src]=$cli_src
	app_args[identity_patches_src]=$identity_patches_src
	app_args[identity_patches_ver]=$identity_patches_ver

	app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
	if [ -n "${app_args[excluded_patches]}" ] && [[ ${app_args[excluded_patches]} != *'"'* ]]; then abort "patch names inside excluded-patches must be quoted"; fi
	app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
	if [ -n "${app_args[included_patches]}" ] && [[ ${app_args[included_patches]} != *'"'* ]]; then abort "patch names inside included-patches must be quoted"; fi
	app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) && vtf "${app_args[exclusive_patches]}" "exclusive-patches" || app_args[exclusive_patches]=false
	app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
	if [ -n "${BUILD_VERSION:-}" ]; then app_args[version]="$BUILD_VERSION"; fi
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[launcher_name]=$(toml_get "$t" launcher-name) || app_args[launcher_name]=""
	app_args[launcher_icon_overlay]=$(toml_get "$t" launcher-icon-overlay) || app_args[launcher_icon_overlay]=""
	app_args[patcher_args]=$(toml_get "$t" patcher-args) || app_args[patcher_args]=""
	app_args[table]=$table_name
	app_args[package_identity]=$(package_identity_for_app "$table_name") || app_args[package_identity]=""
	app_args[build_mode]=$(toml_get "$t" build-mode) && {
		if ! isoneof "${app_args[build_mode]}" both apk module; then
			abort "ERROR: build-mode '${app_args[build_mode]}' is not a valid option for '${table_name}': only 'both', 'apk' or 'module' is allowed"
		fi
	} || app_args[build_mode]=apk
	if [ -n "${BUILD_MODE:-}" ]; then
		if ! isoneof "$BUILD_MODE" apk module; then abort "invalid BUILD_MODE '$BUILD_MODE'"; fi
		app_args[build_mode]="$BUILD_MODE"
	fi
	app_args[include_stock]=$(toml_get "$t" include-stock) && {
		if ! isoneof "${app_args[include_stock]}" disable merged split; then
			abort "ERROR: include-stock '${app_args[include_stock]}' is not a valid option for '${table_name}': only 'disable', 'merged' or 'split' is allowed"
		fi
	} || app_args[include_stock]=merged

	app_args[pkg_name]=$(toml_get "$t" pkg-name) || app_args[pkg_name]=""
	for dl_from in "${CONFIG_DL_SRCS[@]}"; do
		if app_args[${dl_from}_dlurl]=$(toml_get "$t" "${dl_from}-dlurl"); then
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%/}
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%download}
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%/}
		else
			app_args[${dl_from}_dlurl]=""
		fi
	done

	# API/tool-backed stock sources are derived from the upstream package name,
	# so apps do not need brittle per-site URLs just to gain a fallback. They can
	# be disabled globally or per app without changing the explicit mirror list.
	app_args[enable_aptoide]=$(toml_get "$t" enable-aptoide) || app_args[enable_aptoide]=$DEF_ENABLE_APTOIDE
	app_args[enable_apkpure]=$(toml_get "$t" enable-apkpure) || app_args[enable_apkpure]=$DEF_ENABLE_APKPURE
	vtf "${app_args[enable_aptoide]}" "enable-aptoide"
	vtf "${app_args[enable_apkpure]}" "enable-apkpure"
	if [ -n "${app_args[pkg_name]}" ] && [ "${app_args[enable_aptoide]}" = true ]; then
		app_args[aptoide_dlurl]=${app_args[pkg_name]}
	else
		app_args[aptoide_dlurl]=""
	fi
	if [ -n "${app_args[pkg_name]}" ] && [ "${app_args[enable_apkpure]}" = true ]; then
		app_args[apkpure_dlurl]=${app_args[pkg_name]}
	else
		app_args[apkpure_dlurl]=""
	fi
	app_args[dl_from]=""
	for dl_candidate in "${DL_SRCS[@]}"; do
		if [ -n "${app_args[${dl_candidate}_dlurl]-}" ]; then
			app_args[dl_from]=$dl_candidate
			break
		fi
	done
	[ -n "${app_args[dl_from]}" ] || abort "ERROR: no stock download source was enabled for '$table_name'. (${DL_SRCS[*]})"
	app_arches=()
	if [ "${BUILD_SOURCE_ONLY:-false}" = true ]; then
		app_arches=("universal")
	elif [ -n "${BUILD_ARCH:-}" ]; then
		if [ "$BUILD_ARCH" = all ]; then app_arches=("universal"); else app_arches=("$BUILD_ARCH"); fi
	elif jq -e '.arches | type == "array" and length > 0' >/dev/null <<<"$t"; then
		mapfile -t app_arches < <(jq -r '.arches[] | if . == "all" then "universal" else . end' <<<"$t")
	else
		app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="auto"
		case "${app_args[arch]}" in
			auto|all) app_arches=("universal" "arm64-v8a" "arm-v7a" "x86_64" "x86") ;;
			both) app_arches=("arm64-v8a" "arm-v7a") ;;
			*) app_arches=("${app_args[arch]}") ;;
		esac
	fi
	for app_arch in "${app_arches[@]}"; do
		if ! isoneof "$app_arch" "universal" "arm64-v8a" "arm-v7a" "x86_64" "x86"; then
			abort "wrong arch '$app_arch' for '$table_name'"
		fi
	done

	app_args[dpi]=$(toml_get "$t" dpi) || app_args[dpi]=""
	table_name_f=${table_name,,}
	table_name_f=${table_name_f// /-}
	app_args[module_prop_name]=$(toml_get "$t" module-prop-name) || app_args[module_prop_name]="${table_name_f}-jhc"

	module_prop_name_b=${app_args[module_prop_name]}
	for app_arch in "${app_arches[@]}"; do
		app_args[table]="$table_name"
		app_args[arch]="$app_arch"
		app_args[module_prop_name]="$module_prop_name_b"
		case "$app_arch" in
			arm64-v8a)
				app_args[table]="$table_name (arm64-v8a)"
				app_args[module_prop_name]="${module_prop_name_b}-arm64"
				;;
			arm-v7a)
				app_args[table]="$table_name (arm-v7a)"
				app_args[module_prop_name]="${module_prop_name_b}-arm"
				;;
			x86_64) app_args[module_prop_name]="${module_prop_name_b}-x64" ;;
			x86) app_args[module_prop_name]="${module_prop_name_b}-x86" ;;
		esac
		if ((idx >= PARALLEL_JOBS)); then
			wait -n
			idx=$((idx - 1))
		fi
		idx=$((idx + 1))
		build_app "$(declare -p app_args)" &
	done
done
wait
_clean_tmp
if [ "${BUILD_SOURCE_ONLY:-false}" = true ]; then
	if [ -n "${BUILD_SOURCE_OUTPUT_DIR:-}" ] && [ -s "$BUILD_SOURCE_OUTPUT_DIR/source.json" ]; then
		pr "Prepared source inventory for ${BUILD_TARGET:-build}"
		exit 0
	fi
	abort "Source preparation produced no reusable metadata."
fi
if [ "${BUILD_STOCK_ONLY:-false}" = true ]; then
	if [ -n "${BUILD_STOCK_OUTPUT_DIR:-}" ] && { [ -s "$BUILD_STOCK_OUTPUT_DIR/stock.apk" ] || [ -s "$BUILD_STOCK_OUTPUT_DIR/skip.json" ]; }; then
		pr "Prepared stock input for ${BUILD_TARGET:-build} / ${BUILD_ARCH:-unknown}"
		exit 0
	fi
	abort "Stock preparation produced no reusable artifact."
fi
if [ -z "$(find "${BUILD_DIR}" -maxdepth 1 -type f ! -name skip.json -print -quit)" ]; then
	if [ "${BUILD_OPTIONAL_VARIANT:-false}" = true ] && [ -s "${BUILD_DIR}/skip.json" ]; then
		pr "No artifact was produced for this optional auto-discovered variant."
		exit 0
	fi
	abort "All builds failed."
fi

log "\nInstall [Microg](https://github.com/MorpheApp/MicroG-RE/) for non-root YouTube and YT Music APKs"
log "Use [zygisk-detach](https://github.com/j-hc/zygisk-detach) to detach YouTube and YT Music modules from Play Store"
log "$(cat "$TEMP_DIR"/*/changelog.md)"

SKIPPED=$(cat "$TEMP_DIR"/skipped 2>/dev/null || :)
if [ -n "$SKIPPED" ]; then
	log "\nSkipped:"
	log "$SKIPPED"
fi

pr "Done"
