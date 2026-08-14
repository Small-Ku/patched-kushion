#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "unexpected: $*" >&2; exit 2; }
endpoint="${@: -1}"
case "$endpoint" in
  repos/MorpheApp/morphe-patches/releases/latest)
    cat <<'JSON'
{"tag_name":"v1.38.0","assets":[{"id":1001,"name":"patches-1.38.0.mpp","digest":"sha256:aaaa"}]}
JSON
    ;;
  repos/RookieEnough/De-Vanced/releases/latest)
    cat <<'JSON'
{"tag_name":"v1.1.0","assets":[{"id":1002,"name":"patches-1.1.0.mpp","digest":"sha256:bbbb"}]}
JSON
    ;;
  repos/MorpheApp/morphe-desktop/releases/latest)
    cat <<'JSON'
{"tag_name":"v1.13.0","assets":[{"id":2000,"name":"morphe-desktop-1.13.0.jar","digest":"sha256:dddd"},{"id":2001,"name":"morphe-desktop-1.13.0-all.jar","digest":"sha256:cccc"}]}
JSON
    ;;
  repos/MorpheApp/morphe-patches/releases/assets/1001|repos/RookieEnough/De-Vanced/releases/assets/1002|repos/MorpheApp/morphe-desktop/releases/assets/2001)
    printf 'fixture'
    ;;
  repos/example/patched-kushion/releases\?per_page=100\&page=1)
    if [ -n "${FAKE_RELEASES_LIST:-}" ] && [ -f "$FAKE_RELEASES_LIST" ]; then cat "$FAKE_RELEASES_LIST"; else printf '%s\n' '[{"tag_name":"41"},{"tag_name":"39"}]'; fi
    ;;
  repos/example/patched-kushion/releases/tags/42)
    [ -n "${FAKE_RELEASE42:-}" ] && [ -f "$FAKE_RELEASE42" ] && cat "$FAKE_RELEASE42" || exit 1
    ;;
  repos/example/patched-kushion/releases/assets/5000)
    [ -n "${FAKE_RELEASE_STATE:-}" ] && [ -f "$FAKE_RELEASE_STATE" ] && cat "$FAKE_RELEASE_STATE" || exit 1
    ;;
  *) echo "unexpected endpoint: $endpoint" >&2; exit 2 ;;
esac
FAKE
chmod +x "$tmp/bin/gh"
cat > "$tmp/bin/java" <<'FAKE_JAVA'
#!/usr/bin/env bash
set -euo pipefail
pkg="${@: -1}"
case "$pkg" in
  com.google.android.youtube)
    printf '%s\n' 'Most common compatible versions:' '20.14.43 (10 patches)'
    ;;
  com.google.android.apps.youtube.music)
    printf '%s\n' 'Most common compatible versions:' '8.30.54 (10 patches)'
    ;;
  com.google.android.apps.photos)
    printf '%s\n' 'Most common compatible versions:' '7.87.0.957333026 (4 patches)'
    ;;
  *) echo "unexpected package: $pkg" >&2; exit 2 ;;
esac
FAKE_JAVA
chmod +x "$tmp/bin/java"
cat > "$tmp/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
case "$url" in
  *com.google.android.youtube)
    printf '%s\n' '<a href="com.google.android.youtube-20.14.43-all.apk">x</a>'
    ;;
  *com.google.android.apps.youtube.music)
    printf '%s\n' '<a href="com.google.android.apps.youtube.music-8.30.54-arm64-v8a.apk">x</a>' '<a href="com.google.android.apps.youtube.music-8.30.54-arm-v7a.apk">x</a>'
    ;;
  *com.google.android.apps.photos)
    printf '%s\n' '<a href="com.google.android.apps.photos-7.86.0.958430351-all.apkm">x</a>'
    ;;
  *) echo "unexpected inventory URL: $url" >&2; exit 2 ;;
esac
FAKE_CURL
chmod +x "$tmp/bin/curl"
printf '%s\n' '{"schemaVersion":1,"variants":{}}' > "$tmp/state.json"
PATH="$tmp/bin:$PATH" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state.json" --output "$tmp/plan.json" --repository example/patched-kushion > "$tmp/matrix.json"
expected_variants=$(python3 - "$tmp/plan.json" "$root/config.toml" <<'PY_EXPECTED'
import json
import sys
import tomllib
from pathlib import Path
plan = json.loads(Path(sys.argv[1]).read_text())
config = tomllib.loads(Path(sys.argv[2]).read_text())
count = 0
for row in plan["availability"]:
    mode = config["apps"][row["target"]]["build"].get("build-mode", "apk")
    modes = 2 if mode == "both" else 1
    count += len(row["availableArches"]) * modes
print(count)
PY_EXPECTED
)
expected_branches=$(jq '[.availability[] | .availableArches | length] | add' "$tmp/plan.json")
[ "$(jq '.include|length' "$tmp/matrix.json")" -eq "$expected_branches" ]
[ "$(jq '.matrix|length' "$tmp/plan.json")" -eq "$expected_variants" ]
[ "$(jq '.branches|length' "$tmp/plan.json")" -eq "$expected_branches" ]
[ "$(jq '.desired|length' "$tmp/plan.json")" -eq "$expected_variants" ]
[ "$(jq '[.include[] | select(.target=="KouPhotos" and .arch=="arm64-v8a") | .variants[]] | length' "$tmp/matrix.json")" -eq 2 ]
[ "$(jq -r .releaseTag "$tmp/plan.json")" = 42 ]
[ "$(jq '[.desired[]|select(.target=="KouTube")]|length' "$tmp/plan.json")" -eq 10 ]
[ "$(jq '[.desired[]|select(.target=="KouMusik")]|length' "$tmp/plan.json")" -eq 4 ]
[ "$(jq '[.desired[]|select(.target=="KouPhotos")]|length' "$tmp/plan.json")" -eq 10 ]
[ "$(jq '[.desired[]|select(.arch=="all")]|length' "$tmp/plan.json")" -eq 0 ]
[ "$(jq '[.desired[]|select(.target=="KouPhotos" and .arch=="universal")]|length' "$tmp/plan.json")" -eq 2 ]
[ "$(jq '[.desired[]|select(.target=="KouPhotos" and .optional==true)]|length' "$tmp/plan.json")" -eq 10 ]
[ "$(jq -r '[.desired[]|select(.target=="KouPhotos")][0].version' "$tmp/plan.json")" = 7.87.0.957333026 ]
[ -z "$(jq -r '.availability[]|select(.target=="KouPhotos")|.missingArches|join(",")' "$tmp/plan.json")" ]
[ "$(jq -r '.availability[]|select(.target=="KouPhotos")|.archPolicy' "$tmp/plan.json")" = auto ]
[ "$(jq -r '.availability[]|select(.target=="KouPhotos")|.availableArches|join(",")' "$tmp/plan.json")" = universal,arm64-v8a,arm-v7a,x86_64,x86 ]
[ "$(jq -r '.availability[]|select(.target=="KouPhotos")|.archiveMissingArches|join(",")' "$tmp/plan.json")" = universal,arm64-v8a,arm-v7a,x86_64,x86 ]
[ "$(jq -r '.desired[0].cli.assetName' "$tmp/plan.json")" = morphe-desktop-1.13.0-all.jar ]

jq '{tag_name:"42",assets:(.desired|to_entries|map({id:(900+.key),name:(.value.key+".apk")}))}' "$tmp/plan.json" > "$tmp/release42.json"
jq '{schemaVersion:1,generation:.generation,releaseTag:.releaseTag,complete:true,variants:(.desired|to_entries|map({key:.value.key,value:{inputId:.value.inputId,assetId:(900+.key),assetName:(.value.key+".apk"),releaseTag:"42",sha256:"AA"}})|from_entries)}' \
  "$tmp/plan.json" > "$tmp/state-satisfied.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-satisfied.json" --output "$tmp/plan2.json" --repository example/patched-kushion > "$tmp/matrix2.json"
[ "$(jq '.include|length' "$tmp/matrix2.json")" -eq 0 ]
[ "$(jq -r .releaseTag "$tmp/plan2.json")" = 42 ]

jq '.variants["koumusik--arm-v7a--apk"].inputId="stale" | .complete=false' "$tmp/state-satisfied.json" > "$tmp/state-stale.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-stale.json" --output "$tmp/plan3.json" --repository example/patched-kushion > "$tmp/matrix3.json"
[ "$(jq '.include|length' "$tmp/matrix3.json")" -eq 1 ]
[ "$(jq -r '.include[0].key' "$tmp/matrix3.json")" = koumusik--arm-v7a ]
[ "$(jq -r '.include[0].variants[0].key' "$tmp/matrix3.json")" = koumusik--arm-v7a--apk ]
[ "$(jq -r '.include[0].variants[0].mode' "$tmp/matrix3.json")" = apk ]

# Rebuild a variant when its GitHub Release asset is missing.
jq 'del(.assets[0])' "$tmp/release42.json" > "$tmp/release42-missing.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42-missing.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-satisfied.json" --output "$tmp/plan4.json" --repository example/patched-kushion > "$tmp/matrix4.json"
[ "$(jq '.include|length' "$tmp/matrix4.json")" -eq 1 ]

# Recover build state from the release when the update-branch write failed.
gen=$(jq -r .generation "$tmp/plan.json")
printf '[{"tag_name":"42","body":"<!-- patched-kushion-generation:%s -->"},{"tag_name":"41","body":""}]\n' "$gen" > "$tmp/releases-list.json"
cp "$tmp/state-satisfied.json" "$tmp/release-state.json"
jq '.assets += [{"id":5000,"name":"patched-kushion-build-state.json"}]' "$tmp/release42.json" > "$tmp/release42-recover.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42-recover.json" FAKE_RELEASES_LIST="$tmp/releases-list.json" FAKE_RELEASE_STATE="$tmp/release-state.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state.json" --output "$tmp/plan5.json" --repository example/patched-kushion > "$tmp/matrix5.json"
[ "$(jq -r .releaseTag "$tmp/plan5.json")" = 42 ]
[ "$(jq '.include|length' "$tmp/matrix5.json")" -eq 0 ]
echo "pipeline planner test passed"
