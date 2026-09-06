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
{"tag_name":"v1.2.1","assets":[{"id":1002,"name":"patches-1.2.1.mpp","digest":"sha256:bbbb"}]}
JSON
    ;;
  repos/crimera/piko/releases/latest)
    cat <<'JSON'
{"tag_name":"v3.8.0","assets":[{"id":1003,"name":"patches-3.8.0.mpp","digest":"sha256:eeee"}]}
JSON
    ;;
  repos/durgesh0505/chiggi_morphe_patches/releases/latest)
    cat <<'JSON'
{"tag_name":"v1.0.0","assets":[{"id":1004,"name":"patches-1.0.0.mpp","digest":"sha256:ffff"}]}
JSON
    ;;
  repos/MorpheApp/morphe-desktop/releases/latest)
    cat <<'JSON'
{"tag_name":"v1.13.0","assets":[{"id":2000,"name":"morphe-desktop-1.13.0.jar","digest":"sha256:dddd"},{"id":2001,"name":"morphe-desktop-1.13.0-all.jar","digest":"sha256:cccc"}]}
JSON
    ;;
  repos/MorpheApp/morphe-patches/releases/assets/1001|repos/RookieEnough/De-Vanced/releases/assets/1002|repos/crimera/piko/releases/assets/1003|repos/MorpheApp/morphe-desktop/releases/assets/2001)
    printf 'fixture'
    ;;
  repos/durgesh0505/chiggi_morphe_patches/releases/assets/1004)
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
if [ "${FAIL_PACKAGE:-}" = "$pkg" ]; then
  printf '%s\n' 'Most common compatible versions:'
  exit 0
fi
case "$pkg" in
  com.google.android.youtube)
    printf '%s\n' 'Most common compatible versions:' '20.14.43 (10 patches)' '20.13.41 (10 patches)' '20.12.46 (9 patches)'
    ;;
  com.google.android.apps.youtube.music)
    printf '%s\n' 'Most common compatible versions:' '8.30.54 (10 patches)'
    ;;
  com.google.android.apps.photos)
    printf '%s\n' 'Most common compatible versions:' '7.87.0.957333026 (6 patches)'
    ;;
  com.instagram.android)
    printf '%s\n' 'Most common compatible versions:' '435.0.0.37.76 [versionCodes: ARM64_V8A=384510827] (30 patches)'
    ;;
  com.facebook.orca)
    printf '%s\n' 'Most common compatible versions:' '573.0.0.44.88 (7 patches)'
    ;;
  *) echo "unexpected package: $pkg" >&2; exit 2 ;;
esac
FAKE_JAVA
chmod +x "$tmp/bin/java"
cat > "$tmp/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
echo "unexpected stock-provider discovery during patch-auto planning: $*" >&2
exit 2
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
[ "$(jq '.include|length' "$tmp/matrix.json")" -eq "$(jq '[.availability[]]|length' "$tmp/plan.json")" ]
[ "$(jq '.matrix|length' "$tmp/plan.json")" -eq "$expected_variants" ]
[ "$(jq '.branches|length' "$tmp/plan.json")" -eq "$expected_branches" ]
[ "$(jq '.desired|length' "$tmp/plan.json")" -eq "$expected_variants" ]
[ "$(jq '[.include[] | select(.target=="KouPhotos") | .arches[] | select(.arch=="arm64-v8a") | .variants[]] | length' "$tmp/matrix.json")" -eq 2 ]
[ "$(jq -r .releaseTag "$tmp/plan.json")" = 42 ]
[ "$(jq '[.desired[]|select(.target=="KouTube")]|length' "$tmp/plan.json")" -eq 10 ]
[ "$(jq -r '.availability[]|select(.target=="KouTube")|.versionCandidates|join(",")' "$tmp/plan.json")" = 20.14.43,20.13.41 ]
[ "$(jq -r '.desired[]|select(.target=="KouTube")|.candidateInputIds|keys|sort|join(",")' "$tmp/plan.json" | head -1)" = 20.13.41,20.14.43 ]
[ "$(jq '[.desired[]|select(.target=="KouMusik")]|length' "$tmp/plan.json")" -eq 2 ]
[ "$(jq '[.desired[]|select(.target=="KouThreads" or .target=="KouFacebook")]|length' "$tmp/plan.json")" -eq 0 ]
[ "$(jq '[.desired[]|select(.target=="KouPhotos")]|length' "$tmp/plan.json")" -eq 10 ]
[ "$(jq '[.desired[]|select(.arch=="all")]|length' "$tmp/plan.json")" -eq 0 ]
[ "$(jq '[.desired[]|select(.target=="KouPhotos" and .arch=="universal")]|length' "$tmp/plan.json")" -eq 2 ]
[ "$(jq '[.desired[]|select(.target=="KouPhotos" and .optional==true)]|length' "$tmp/plan.json")" -eq 10 ]
[ "$(jq -r '[.desired[]|select(.target=="KouPhotos")][0].version' "$tmp/plan.json")" = 7.87.0.957333026 ]
[ -z "$(jq -r '.availability[]|select(.target=="KouPhotos")|.missingArches|join(",")' "$tmp/plan.json")" ]
[ "$(jq -r '.availability[]|select(.target=="KouPhotos")|.archPolicy' "$tmp/plan.json")" = auto ]
[ "$(jq -r '.availability[]|select(.target=="KouPhotos")|.availableArches|join(",")' "$tmp/plan.json")" = universal,arm64-v8a,arm-v7a,x86_64,x86 ]
[ "$(jq -r '.desired[0].cli.assetName' "$tmp/plan.json")" = morphe-desktop-1.13.0-all.jar ]
[ "$(jq -r '[.desired[]|select(.target=="KouPhotos")|.sourcePriority] | unique | join(",")' "$tmp/plan.json")" = desired ]

# A single target with no compatible patch version is isolated from the rest of
# the plan. Other targets remain schedulable and the blocked reason is retained
# in the plan for CI summaries and health checks.
FAIL_PACKAGE=com.instagram.android PATH="$tmp/bin:$PATH" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state.json" --output "$tmp/plan-blocked.json" --repository example/patched-kushion > "$tmp/matrix-blocked.json"
[ "$(jq '[.blocked[] | select(.target=="KouInstagram" and .status=="blocked")] | length' "$tmp/plan-blocked.json")" -eq 1 ]
[ "$(jq '[.desired[] | select(.target=="KouInstagram")] | length' "$tmp/plan-blocked.json")" -eq 0 ]
[ "$(jq '[.desired[] | select(.target=="KouTube")] | length' "$tmp/plan-blocked.json")" -gt 0 ]
[ "$(jq '.include | length' "$tmp/matrix-blocked.json")" -gt 0 ]
[ "$(jq -r '.targets[]|select(.target=="KouPhotos")|[.arches[].sourcePriority]|unique|join(",")' "$tmp/plan.json")" = desired ]
koutube_apk_profile=$(jq -r '.desired[]|select(.key=="koutube--arm64-v8a--apk")|.patchProfileHash' "$tmp/plan.json")
koutube_module_profile=$(jq -r '.desired[]|select(.key=="koutube--arm64-v8a--module")|.patchProfileHash' "$tmp/plan.json")
koutube_apk_assets=$(jq -r '.desired[]|select(.key=="koutube--arm64-v8a--apk")|.patchAssetHash' "$tmp/plan.json")
koutube_module_assets=$(jq -r '.desired[]|select(.key=="koutube--arm64-v8a--module")|.patchAssetHash' "$tmp/plan.json")
[ -n "$koutube_apk_profile" ] && [ "$koutube_apk_profile" != "$koutube_module_profile" ]
[ -n "$koutube_apk_assets" ] && [ "$koutube_apk_assets" = "$koutube_module_assets" ]
[ "$(jq -r '[.desired[].publishConsistency] | unique | join(",")' "$tmp/plan.json")" = target ]

jq '{tag_name:"42",assets:(.desired|to_entries|map({id:(900+.key),name:(.value.key+".apk")}))}' "$tmp/plan.json" > "$tmp/release42.json"
jq '{schemaVersion:1,generation:.generation,releaseTag:.releaseTag,complete:true,variants:(.desired|to_entries|map({key:.value.key,value:{version:.value.version,inputId:.value.inputId,assetId:(900+.key),assetName:(.value.key+".apk"),releaseTag:"42",sha256:"AA"}})|from_entries)}' \
  "$tmp/plan.json" > "$tmp/state-satisfied.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-satisfied.json" --output "$tmp/plan2.json" --repository example/patched-kushion > "$tmp/matrix2.json"
[ "$(jq '.include|length' "$tmp/matrix2.json")" -eq "$(jq '[.availability[]|select(.forwardProbeLimit>0)]|length' "$tmp/plan2.json")" ]
[ "$(jq '[.matrix[]|select((.reuseByInputId|length)==1)]|length' "$tmp/plan2.json")" -eq "$expected_variants" ]
[ "$(jq -r .releaseTag "$tmp/plan2.json")" = 42 ]

jq '.variants["koumusik--arm64-v8a--apk"].inputId="stale" | .complete=false' "$tmp/state-satisfied.json" > "$tmp/state-stale.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-stale.json" --output "$tmp/plan3.json" --repository example/patched-kushion > "$tmp/matrix3.json"
[ "$(jq '.include|length' "$tmp/matrix3.json")" -eq "$(jq '[.availability[]|select(.forwardProbeLimit>0)]|length' "$tmp/plan3.json")" ]
[ "$(jq '[.matrix[]|select(.key=="koumusik--arm64-v8a--apk")|.reuseByInputId|length] | add // 0' "$tmp/plan3.json")" -eq 0 ]
[ "$(jq '[.matrix[]|select(.key!="koumusik--arm64-v8a--apk" and (.reuseByInputId|length)==1)]|length' "$tmp/plan3.json")" -eq $((expected_variants-1)) ]

# Rebuild a variant when its GitHub Release asset is missing.
jq 'del(.assets[0])' "$tmp/release42.json" > "$tmp/release42-missing.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42-missing.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-satisfied.json" --output "$tmp/plan4.json" --repository example/patched-kushion > "$tmp/matrix4.json"
[ "$(jq '.include|length' "$tmp/matrix4.json")" -eq "$(jq '[.availability[]|select(.forwardProbeLimit>0)]|length' "$tmp/plan4.json")" ]
[ "$(jq '[.matrix[]|select((.reuseByInputId|length)==0)]|length' "$tmp/plan4.json")" -eq 1 ]

# A previously patched older compatible version is exposed as a reusable fallback.
fallback_input=$(jq -r '.desired[]|select(.key=="koutube--arm64-v8a--apk")|.candidateInputIds["20.13.41"]' "$tmp/plan.json")
jq --arg input "$fallback_input" '.variants["koutube--arm64-v8a--apk"] += {version:"20.13.41",inputId:$input}' "$tmp/state-satisfied.json" > "$tmp/state-fallback.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-fallback.json" --output "$tmp/plan-fallback.json" --repository example/patched-kushion > "$tmp/matrix-fallback.json"
[ "$(jq -r '.include[]|select(.target=="KouTube")|.arches[]|select(.arch=="arm64-v8a")|.variants[]|select(.mode=="apk")|.reuseByInputId[]|.version' "$tmp/matrix-fallback.json")" = 20.13.41 ]

# The per-generation ledger retains every successfully published compatible
# input, not only the preferred state variant. All matching inputs are offered
# to version fan-out for reuse on subsequent discovery runs.
jq '.assets += [{"id":1999,"name":"koutube-v20.13.41.apk"}]' "$tmp/release42.json" > "$tmp/release42-ledger.json"
jq --arg input "$fallback_input" '.artifactsByInputId={($input):{version:"20.13.41",inputId:$input,target:"KouTube",arch:"arm64-v8a",mode:"apk",assetId:1999,assetName:"koutube-v20.13.41.apk",sha256:"BB",releaseTag:"42"}}' "$tmp/state-satisfied.json" > "$tmp/state-ledger.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42-ledger.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state-ledger.json" --output "$tmp/plan-ledger.json" --repository example/patched-kushion > "$tmp/matrix-ledger.json"
[ "$(jq '.matrix[]|select(.key=="koutube--arm64-v8a--apk")|.reuseByInputId|length' "$tmp/plan-ledger.json")" -eq 2 ]
[ "$(jq -r --arg input "$fallback_input" '.matrix[]|select(.key=="koutube--arm64-v8a--apk")|.reuseByInputId[$input].version' "$tmp/plan-ledger.json")" = 20.13.41 ]

# Recover build state from the release when the update-branch write failed.
gen=$(jq -r .generation "$tmp/plan.json")
printf '[{"tag_name":"42","body":"<!-- patched-kushion-generation:%s -->"},{"tag_name":"41","body":""}]\n' "$gen" > "$tmp/releases-list.json"
cp "$tmp/state-satisfied.json" "$tmp/release-state.json"
jq '.assets += [{"id":5000,"name":"patched-kushion-build-state.json"}]' "$tmp/release42.json" > "$tmp/release42-recover.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42-recover.json" FAKE_RELEASES_LIST="$tmp/releases-list.json" FAKE_RELEASE_STATE="$tmp/release-state.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" \
  --state "$tmp/state.json" --output "$tmp/plan5.json" --repository example/patched-kushion > "$tmp/matrix5.json"
[ "$(jq -r .releaseTag "$tmp/plan5.json")" = 42 ]
[ "$(jq '.include|length' "$tmp/matrix5.json")" -eq "$(jq '[.availability[]|select(.forwardProbeLimit>0)]|length' "$tmp/plan5.json")" ]
[ "$(jq '[.matrix[]|select((.reuseByInputId|length)==1)]|length' "$tmp/plan5.json")" -eq "$expected_variants" ]
echo "pipeline planner test passed"
