#!/usr/bin/env bash
# Run through Pixi with a downloaded, pinned-signer APKM and APKEDITOR_JAR.
# Usage: pixi run bash scripts/benchmark-stock-cache.sh BUNDLE PACKAGE VERSION OUTPUT
set -euo pipefail
cd "$(dirname "$0")/.."
source utils.sh
# utils.sh's existing JVM wrapper accepts this explicit location. Keep benchmark
# execution on the activated Pixi JVM even on hosts with no system Java.
if [ -n "${CONDA_PREFIX:-}" ] && [ -z "${JAVA_HOME_21_X64:-}" ]; then
  JAVA_HOME_21_X64=$CONDA_PREFIX
fi
bundle=$(realpath "$1") package=$2 version=$3 output=$(realpath -m "$4")
test ! -e "$output" || { echo >&2 'Benchmark output must be a new directory'; exit 2; }
test -n "${APKEDITOR_JAR:-}" || { echo >&2 'Set APKEDITOR_JAR to a digest-verified APKEditor'; exit 2; }
mkdir -p "$output"
TEMP_DIR="$output/temp"; mkdir -p "$TEMP_DIR"
BUILD_DIR="$output/build"
BUILD_TARGET=Benchmark BUILD_VERSION="$version" BUILD_SOURCE_CACHE_KEY=benchmark-source
BUILD_SOURCE_OUTPUT_DIR="$output/source"
set_prebuilts
__TOML__=$(python3 -c 'import json,tomllib; print(json.dumps(tomllib.load(open("config.toml","rb"))))')
declare -A args=([archive_dlurl]='https://archive.org/download/jhc-apks')
printf '{"format":"APKM"}\n' > "$output/input.apkm.source.json"
cp "$bundle" "$output/input.apkm"
prepare_generic_shared_payload archive "$output/input.apkm" "$package" "$version" \
  '[{"arch":"universal","optional":false},{"arch":"arm64-v8a","optional":false}]' "$BUILD_SOURCE_OUTPUT_DIR"
verify_prepared_source_acquisition "$package" "$version" ''
python3 scripts/stock_cache.py seal-source --root "$BUILD_SOURCE_OUTPUT_DIR" --source-key "$BUILD_SOURCE_CACHE_KEY"
unset BUILD_SOURCE_OUTPUT_DIR
for BUILD_ARCH in universal arm64-v8a; do
  BUILD_STOCK_DIR="$output/$BUILD_ARCH/normalized"
  BUILD_PATCH_OUTPUT_DIR="$output/$BUILD_ARCH/diagnostics"
  python3 scripts/stock_cache.py prepare --root "$output/source" --output "$BUILD_STOCK_DIR" \
    --target Benchmark --version "$version" --arch "$BUILD_ARCH" --source-key "$BUILD_SOURCE_CACHE_KEY"
  import_stock_result "$output/$BUILD_ARCH/stock.apk"
  BUILD_STOCK_OUTPUT_DIR="$output/$BUILD_ARCH/prepared"
  export_stock_result "$output/$BUILD_ARCH/stock.apk" "$package" "$version" "$BUILD_ARCH"
  unset BUILD_STOCK_OUTPUT_DIR
done
python3 scripts/benchmark_stock_cache.py --root "$output" --bundle "$bundle" --apkeditor "$APKEDITOR_JAR"
