#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/observations.json" <<'JSON'
[
  {"source":"direct","configured":true,"status":"ready","versions":[],"versionOpaque":true},
  {"source":"apkmirror","configured":true,"status":"ready","versions":["2.0","1.0"],"versionOpaque":false},
  {"source":"apkfab","configured":true,"status":"ready","versions":["2.0"],"versionOpaque":false},
  {"source":"apkpure","configured":true,"status":"ready","versions":["2.0"],"versionOpaque":false},
  {"source":"archive","configured":true,"status":"ready","versions":["1.0"],"versionOpaque":false},
  {"source":"uptodown","configured":true,"status":"unavailable","versions":[],"versionOpaque":false},
  {"source":"aptoide","configured":true,"status":"ready","versions":["2.0"],"versionOpaque":false}
]
JSON

python3 scripts/source_graph.py \
  --observations "$tmp/observations.json" \
  --versions-json '["3.0","2.0","1.0"]' \
  --arches-json '[{"arch":"arm64-v8a","sourcePriority":"required"},{"arch":"arm-v7a","optional":true,"sourcePriority":"desired"}]' \
  --output "$tmp/graph.json" >/dev/null

# Versions with actual provider evidence are traversed before blind exact-version
# probes; newest-compatible order remains stable within each class.
[ "$(jq -r '.versionTraversal | join(",")' "$tmp/graph.json")" = '2.0,1.0,3.0' ]
[ "$(jq -r '.versions[] | select(.version=="2.0") | .advertisedSources | join(",")' "$tmp/graph.json")" = 'apkmirror,apkfab,apkpure,aptoide' ]
# Direct is version-opaque, so it remains an explicit exact-version probe rather
# than pretending to advertise every compatible version. Metadata-failed
# providers also remain explicit probes, ordered after positive evidence.
[ "$(jq -r '.versions[] | select(.version=="2.0") | .broadSources | join(",")' "$tmp/graph.json")" = 'apkmirror,apkpure,direct,archive,uptodown' ]
# APKFab device-profile XAPKs are branch-only: they can satisfy an exact ABI
# node but must never be promoted into the reusable broad/universal path.
! jq -e '.nodes[] | select(.id=="acquire:2.0:broad:apkfab")' "$tmp/graph.json" >/dev/null
jq -e '.nodes[] | select(.id=="acquire:2.0:branch:arm64-v8a:apkfab" and .evidence=="advertised")' "$tmp/graph.json" >/dev/null
[ "$(jq -r '.versions[] | select(.version=="2.0") | .branchSources | join(",")' "$tmp/graph.json")" = 'apkmirror,apkfab,apkpure,aptoide,direct,archive,uptodown' ]
jq -e '.nodes[] | select(.id=="discover:apkpure" and .kind=="discovery")' "$tmp/graph.json" >/dev/null
jq -e '.nodes[] | select(.id=="acquire:2.0:branch:arm64-v8a:apkpure" and .evidence=="advertised")' "$tmp/graph.json" >/dev/null
jq -e '.nodes[] | select(.id=="acquire:2.0:branch:arm64-v8a:archive" and .evidence=="probe")' "$tmp/graph.json" >/dev/null
jq -e '.edges[] | select(.from=="discover:apkmirror" and .to=="version:2.0")' "$tmp/graph.json" >/dev/null

# Exercise shell-side discovery: every configured provider is queried before
# payload traversal and its version evidence is persisted in the graph.
# shellcheck disable=SC1091
source "$root/utils.sh"
TEMP_DIR="$tmp/runtime"; mkdir -p "$TEMP_DIR"
declare -A args
args[aptoide_dlurl]=pkg
args[apkpure_dlurl]=pkg
args[archive_dlurl]=archive
DL_SRCS=(aptoide apkpure archive)
get_aptoide_resp() { printf 'aptoide\n' >> "$tmp/probes"; return 0; }
get_aptoide_vers() { printf '%s\n' 2.0; }
get_apkpure_resp() { printf 'apkpure\n' >> "$tmp/probes"; return 0; }
get_apkpure_vers() { printf '%s\n' 2.0 1.0; }
get_archive_resp() { printf 'archive\n' >> "$tmp/probes"; return 0; }
get_archive_vers() { printf '%s\n' 1.0; }
source_provenance_family() { printf '%s\n' "$1"; }
source_provenance_domain() { printf '%s.example\n' "$1"; }

discover_stock_source_graph pkg \
  '[{"arch":"arm64-v8a","sourcePriority":"required"}]' \
  '["2.0","1.0"]' "$tmp/runtime-graph.json"
[ "$(sort "$tmp/probes" | paste -sd, -)" = 'apkpure,aptoide,archive' ]
[ "$(jq -r '.providers[] | select(.source=="apkpure") | .versions | join(",")' "$tmp/runtime-graph.json")" = '1.0,2.0' ]
[ "$(jq -r '.versionTraversal | join(",")' "$tmp/runtime-graph.json")" = '2.0,1.0' ]


# Forward compatibility probing is bounded and explicitly distinguished from
# patch-declared compatibility. Provider-advertised newer stock versions become
# independent DAG nodes rather than replacing the known-good boundary.
python3 scripts/source_graph.py \
  --observations "$tmp/observations.json" \
  --versions-json '["2.0","1.0"]' \
  --arches-json '[{"arch":"arm64-v8a","sourcePriority":"required"}]' \
  --forward-probe-limit 2 \
  --output "$tmp/forward-graph.json" >/dev/null
[ "$(jq -r '.forwardProbeVersions | join(",")' "$tmp/forward-graph.json")" = '' ]

cat > "$tmp/forward-observations.json" <<'JSON'
[
  {"source":"apkmirror","configured":true,"status":"ready","versions":["4.0","3.0","2.0"],"versionOpaque":false},
  {"source":"apkpure","configured":true,"status":"ready","versions":["4.0","2.0"],"versionOpaque":false}
]
JSON
python3 scripts/source_graph.py \
  --observations "$tmp/forward-observations.json" \
  --versions-json '["2.0","1.0"]' \
  --arches-json '[{"arch":"arm64-v8a","sourcePriority":"required"}]' \
  --forward-probe-limit 2 \
  --output "$tmp/forward-graph.json" >/dev/null
[ "$(jq -r '.forwardProbeVersions | join(",")' "$tmp/forward-graph.json")" = '4.0,3.0' ]
[ "$(jq -r '.versionTraversal | join(",")' "$tmp/forward-graph.json")" = '4.0,3.0,2.0,1.0' ]
[ "$(jq -r '.versions[] | select(.version=="4.0") | .compatibility' "$tmp/forward-graph.json")" = forward-probe ]
[ "$(jq -r '.versions[] | select(.version=="2.0") | .compatibility' "$tmp/forward-graph.json")" = declared ]

echo 'source graph test passed'

# End-to-end source-stage traversal follows graph evidence rather than the raw
# planner list. Version 3.0 is newest but no provider advertises it, so 2.0 is
# attempted first and succeeds without probing 3.0 payloads.
rm -f "$tmp/probes" "$tmp/attempts"
BUILD_SOURCE_OUTPUT_DIR="$tmp/source-out"
BUILD_TARGET=Fixture
args[aptoide_dlurl]=pkg
args[apkpure_dlurl]=pkg
args[archive_dlurl]=archive
DL_SRCS=(aptoide apkpure archive)
get_aptoide_vers() { printf '%s\n' 1.0; }
get_apkpure_vers() { printf '%s\n' 2.0; }
get_archive_vers() { printf '%s\n' 1.0; }
prepare_shared_stock_source() {
  local _pkg=$1 version=$2 _dpi=$3 _arches=$4 _graph=$5
  printf '%s\n' "$version" >> "$tmp/attempts"
  rm -rf "$BUILD_SOURCE_OUTPUT_DIR"; mkdir -p "$BUILD_SOURCE_OUTPUT_DIR"
  if [ "$version" = 2.0 ]; then
    printf '%s\n' '{"schemaVersion":2,"status":"ready","shared":true,"strategy":"branches","version":"2.0","availableBuildArches":["arm64-v8a"],"coverage":{"missingRequired":[]}}' > "$BUILD_SOURCE_OUTPUT_DIR/source.json"
  else
    printf '%s\n' '{"schemaVersion":2,"status":"unavailable","shared":false,"strategy":"branches","availableBuildArches":[],"coverage":{"missingRequired":["arm64-v8a"]}}' > "$BUILD_SOURCE_OUTPUT_DIR/source.json"
  fi
}
verify_prepared_source_acquisition() { return 0; }
prepare_branch_stock_sources() { return 1; }
prepare_stock_source_candidates pkg '' '[{"arch":"arm64-v8a","sourcePriority":"required"}]' '["3.0","2.0","1.0"]'
[ "$(cat "$tmp/attempts")" = 2.0 ]
[ "$(jq -r .version "$tmp/source-out/source.json")" = 2.0 ]
[ -s "$tmp/source-out/source-graph.json" ]

echo 'source DAG traversal test passed'
