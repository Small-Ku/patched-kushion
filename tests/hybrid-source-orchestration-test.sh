#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; mkdir -p "$TEMP_DIR"
BUILD_SOURCE_OUTPUT_DIR="$tmp/out"
BUILD_TARGET=Fixture

# Keep the orchestration test independent from network/parser details: discovery
# produces one version, the broad phase yields only universal, and completion
# must be invoked with preserve=true to add the missing ABI branch.
discover_stock_source_graph() {
  cat > "$4" <<'JSON'
{"kind":"source-acquisition-dag","versionTraversal":["2.0"],"providers":[{"source":"apkpure"}],"versions":[{"version":"2.0","broadSources":["apkpure"],"branchSources":["apkpure","apkmirror"]}]}
JSON
}
prepare_shared_stock_source() {
  rm -rf "$BUILD_SOURCE_OUTPUT_DIR"; mkdir -p "$BUILD_SOURCE_OUTPUT_DIR/branches/universal"
  printf fat > "$BUILD_SOURCE_OUTPUT_DIR/branches/universal/stock.apk"
  printf '%s\n' '{"available":true,"arch":"universal","sourceName":"apkpure","format":"APK"}' > "$BUILD_SOURCE_OUTPUT_DIR/branches/universal/branch.json"
  cat > "$BUILD_SOURCE_OUTPUT_DIR/source.json" <<'JSON'
{"schemaVersion":2,"status":"ready","shared":true,"strategy":"branches","sourceName":"apkpure","availableBuildArches":["universal"],"coverage":{"required":[],"desired":["universal","arm64-v8a"],"optional":[],"available":["universal"],"missingRequired":[],"missingDesired":["arm64-v8a"],"missingOptional":[]}}
JSON
}
materialize_prepared_source_branches() { return 0; }
prepare_branch_stock_sources() {
  [ "${6:-false}" = true ] || { echo 'partial broad source was not preserved' >&2; return 1; }
  test -f "$BUILD_SOURCE_OUTPUT_DIR/branches/universal/stock.apk"
  mkdir -p "$BUILD_SOURCE_OUTPUT_DIR/branches/arm64-v8a"
  printf arm64 > "$BUILD_SOURCE_OUTPUT_DIR/branches/arm64-v8a/stock.apk"
  printf '%s\n' '{"available":true,"arch":"arm64-v8a","sourceName":"apkmirror","format":"BUNDLE"}' > "$BUILD_SOURCE_OUTPUT_DIR/branches/arm64-v8a/branch.json"
  cat > "$BUILD_SOURCE_OUTPUT_DIR/source.json" <<'JSON'
{"schemaVersion":2,"status":"ready","shared":true,"strategy":"branches","hybrid":true,"sourceName":"mixed","availableBuildArches":["universal","arm64-v8a"],"coverage":{"required":[],"desired":["universal","arm64-v8a"],"optional":[],"available":["universal","arm64-v8a"],"missingRequired":[],"missingDesired":[],"missingOptional":[]}}
JSON
}
verify_prepared_source_acquisition() { return 0; }

prepare_stock_source_candidates pkg '' \
  '[{"arch":"universal","optional":true,"sourcePriority":"desired"},{"arch":"arm64-v8a","optional":true,"sourcePriority":"desired"}]' \
  '["2.0"]'

jq -e '.hybrid == true and .availableBuildArches == ["universal","arm64-v8a"]' "$BUILD_SOURCE_OUTPUT_DIR/source.json" >/dev/null
test -f "$BUILD_SOURCE_OUTPUT_DIR/branches/universal/stock.apk"
test -f "$BUILD_SOURCE_OUTPUT_DIR/branches/arm64-v8a/stock.apk"
test -s "$BUILD_SOURCE_OUTPUT_DIR/source-graph.json"
echo 'hybrid source orchestration test passed'
