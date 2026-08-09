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
{"tag_name":"v1.13.0","assets":[{"id":2001,"name":"morphe-desktop-1.13.0-all.jar","digest":"sha256:cccc"}]}
JSON
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
printf '%s\n' '{"schemaVersion":1,"variants":{}}' > "$tmp/state.json"
PATH="$tmp/bin:$PATH" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" --identities "$root/package-identities.toml" \
  --state "$tmp/state.json" --output "$tmp/plan.json" --repository example/patched-kushion > "$tmp/matrix.json"
[ "$(jq '.include|length' "$tmp/matrix.json")" -eq 10 ]
[ "$(jq -r .releaseTag "$tmp/plan.json")" = 42 ]
[ "$(jq '[.desired[]|select(.target=="YouTube-Morphe")]|length' "$tmp/plan.json")" -eq 2 ]
[ "$(jq '[.desired[]|select(.target=="Music-Morphe")]|length' "$tmp/plan.json")" -eq 4 ]
[ "$(jq '[.desired[]|select(.target=="GooglePhotos-DeVanced")]|length' "$tmp/plan.json")" -eq 4 ]

jq '{tag_name:"42",assets:(.desired|to_entries|map({id:(900+.key),name:(.value.key+".apk")}))}' "$tmp/plan.json" > "$tmp/release42.json"
jq '{schemaVersion:1,generation:.generation,releaseTag:.releaseTag,complete:true,variants:(.desired|to_entries|map({key:.value.key,value:{inputId:.value.inputId,assetId:(900+.key),assetName:(.value.key+".apk"),releaseTag:"42",sha256:"AA"}})|from_entries)}' \
  "$tmp/plan.json" > "$tmp/state-satisfied.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" --identities "$root/package-identities.toml" \
  --state "$tmp/state-satisfied.json" --output "$tmp/plan2.json" --repository example/patched-kushion > "$tmp/matrix2.json"
[ "$(jq '.include|length' "$tmp/matrix2.json")" -eq 0 ]
[ "$(jq -r .releaseTag "$tmp/plan2.json")" = 42 ]

jq '.variants["music-morphe--arm-v7a--apk"].inputId="stale" | .complete=false' "$tmp/state-satisfied.json" > "$tmp/state-stale.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" --identities "$root/package-identities.toml" \
  --state "$tmp/state-stale.json" --output "$tmp/plan3.json" --repository example/patched-kushion > "$tmp/matrix3.json"
[ "$(jq '.include|length' "$tmp/matrix3.json")" -eq 1 ]
[ "$(jq -r '.include[0].key' "$tmp/matrix3.json")" = music-morphe--arm-v7a--apk ]

# A checkpoint whose GitHub release asset disappeared is not satisfied.
jq 'del(.assets[0])' "$tmp/release42.json" > "$tmp/release42-missing.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42-missing.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" --identities "$root/package-identities.toml" \
  --state "$tmp/state-satisfied.json" --output "$tmp/plan4.json" --repository example/patched-kushion > "$tmp/matrix4.json"
[ "$(jq '.include|length' "$tmp/matrix4.json")" -eq 1 ]

# If release upload succeeded but checkpoint push failed, recover the release by generation marker.
gen=$(jq -r .generation "$tmp/plan.json")
printf '[{"tag_name":"42","body":"<!-- patched-kushion-generation:%s -->"},{"tag_name":"41","body":""}]\n' "$gen" > "$tmp/releases-list.json"
cp "$tmp/state-satisfied.json" "$tmp/release-state.json"
jq '.assets += [{"id":5000,"name":"patched-kushion-build-state.json"}]' "$tmp/release42.json" > "$tmp/release42-recover.json"
PATH="$tmp/bin:$PATH" FAKE_RELEASE42="$tmp/release42-recover.json" FAKE_RELEASES_LIST="$tmp/releases-list.json" FAKE_RELEASE_STATE="$tmp/release-state.json" python3 "$root/scripts/pipeline_plan.py" \
  --config "$root/config.toml" --identities "$root/package-identities.toml" \
  --state "$tmp/state.json" --output "$tmp/plan5.json" --repository example/patched-kushion > "$tmp/matrix5.json"
[ "$(jq -r .releaseTag "$tmp/plan5.json")" = 42 ]
[ "$(jq '.include|length' "$tmp/matrix5.json")" -eq 0 ]
echo "pipeline planner test passed"
