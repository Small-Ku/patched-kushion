#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fake/assets" "$tmp/artifacts/a" "$tmp/artifacts/b-skip"
printf '%s\n' '{"next":700,"releases":{}}' > "$tmp/fake/state.json"
cat > "$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
state_path=Path(os.environ['FAKE_GH_STATE']); root=state_path.parent
state=json.loads(state_path.read_text()); args=sys.argv[1:]
def save(): state_path.write_text(json.dumps(state))
def rel(tag): return state['releases'].get(tag)
if args[:2]==['release','view']:
    sys.exit(0 if rel(args[2]) else 1)
if args[:2]==['release','create']:
    tag=args[2]; state['releases'].setdefault(tag,{'tag_name':tag,'assets':[]}); save(); sys.exit(0)
if args[:2]==['release','upload']:
    tag,path=args[2],Path(args[3]); r=state['releases'][tag]
    r['assets']=[a for a in r['assets'] if a['name']!=path.name]
    aid=state['next']; state['next']+=1
    dest=root/'assets'/str(aid); shutil.copyfile(path,dest)
    r['assets'].append({'id':aid,'name':path.name}); save(); sys.exit(0)
if args[:2]==['release','edit']: sys.exit(0)
if args and args[0]=='api':
    endpoint=args[-1]
    if '/releases/tags/' in endpoint:
        tag=endpoint.rsplit('/',1)[1]; print(json.dumps(state['releases'][tag])); sys.exit(0)
    if '/releases/assets/' in endpoint:
        aid=endpoint.rsplit('/',1)[1]; sys.stdout.buffer.write((root/'assets'/aid).read_bytes()); sys.exit(0)
print('unexpected gh '+repr(args),file=sys.stderr); sys.exit(2)
PY
chmod +x "$tmp/bin/gh"
cat > "$tmp/plan.json" <<'JSON'
{
  "schemaVersion":1,"repository":"example/patched-kushion","generation":"gen1","releaseTag":"7",
  "desired":[
    {"key":"a--universal--apk","target":"A","arch":"universal","mode":"apk","inputId":"input-a","optional":false},
    {"key":"b--x86--apk","target":"B","arch":"x86","mode":"apk","inputId":"input-b","optional":true}
  ],
  "matrix":[]
}
JSON
printf '%s\n' '{"schemaVersion":1,"variants":{}}' > "$tmp/state.json"
printf 'apk-a' > "$tmp/artifacts/a/a.apk"
sha=$(sha256sum "$tmp/artifacts/a/a.apk"|awk '{print toupper($1)}')
cat > "$tmp/artifacts/a/result.json" <<JSON
{"schemaVersion":1,"key":"a--universal--apk","inputId":"input-a","target":"A","arch":"universal","mode":"apk","assetName":"a.apk","sha256":"$sha","buildLog":""}
JSON
cat > "$tmp/artifacts/b-skip/result.json" <<'JSON'
{"schemaVersion":1,"key":"b--x86--apk","inputId":"input-b","target":"B","arch":"x86","mode":"apk","skipped":true,"reason":"stock x86 unavailable"}
JSON
PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/fake/state.json" python3 "$root/scripts/publish_release.py" \
  --plan "$tmp/plan.json" --state "$tmp/state.json" --artifacts "$tmp/artifacts" --output-dir "$tmp/out1"
[ "$(jq -r .complete "$tmp/out1/build-state.json")" = true ]
[ "$(jq '.variants|length' "$tmp/out1/build-state.json")" -eq 1 ]
[ "$(jq -r '.variants["a--universal--apk"].inputId' "$tmp/out1/build-state.json")" = input-a ]
[ "$(jq -r '.unavailable["b--x86--apk"].reason' "$tmp/out1/build-state.json")" = 'stock x86 unavailable' ]

# Auto-discovered missing variants are not persisted as satisfied; a later run can
# add the ABI to the same generation/release as soon as an upstream source gains it.
rm -rf "$tmp/artifacts"; mkdir -p "$tmp/artifacts/b"
printf 'apk-b' > "$tmp/artifacts/b/b.apk"
sha=$(sha256sum "$tmp/artifacts/b/b.apk"|awk '{print toupper($1)}')
cat > "$tmp/artifacts/b/result.json" <<JSON
{"schemaVersion":1,"key":"b--x86--apk","inputId":"input-b","target":"B","arch":"x86","mode":"apk","assetName":"b.apk","sha256":"$sha","buildLog":""}
JSON
PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/fake/state.json" python3 "$root/scripts/publish_release.py" \
  --plan "$tmp/plan.json" --state "$tmp/out1/build-state.json" --artifacts "$tmp/artifacts" --output-dir "$tmp/out2"
[ "$(jq -r .complete "$tmp/out2/build-state.json")" = true ]
[ "$(jq '.variants|length' "$tmp/out2/build-state.json")" -eq 2 ]
[ "$(jq '.unavailable|length' "$tmp/out2/build-state.json")" -eq 0 ]
[ "$(jq -r .releaseTag "$tmp/out2/build-state.json")" = 7 ]
[ "$(jq '.releases["7"].assets|length' "$tmp/fake/state.json")" -eq 3 ]
echo "release publisher optional-variant retry test passed"

# A compatible older patch result can satisfy the generation while the preferred
# stock version remains unavailable. The old asset is copied into the current
# release so F-Droid and module-update URLs stay release-local.
printf 'apk-c-old' > "$tmp/fake/assets/888"
oldsha=$(sha256sum "$tmp/fake/assets/888"|awk '{print toupper($1)}')
cat > "$tmp/plan-fallback.json" <<'JSON'
{
  "schemaVersion":1,"repository":"example/patched-kushion","generation":"gen2","releaseTag":"8",
  "desired":[
    {"key":"c--arm64-v8a--apk","target":"C","arch":"arm64-v8a","mode":"apk","version":"2.0","inputId":"input-c-new","candidateInputIds":{"2.0":"input-c-new","1.9":"input-c-old"},"optional":false}
  ],
  "matrix":[]
}
JSON
cat > "$tmp/state-fallback.json" <<JSON
{"schemaVersion":1,"variants":{"c--arm64-v8a--apk":{"version":"1.9","inputId":"input-c-old","assetId":888,"assetName":"c-v1.9.apk","sha256":"$oldsha","releaseTag":"6"}}}
JSON
rm -rf "$tmp/artifacts"; mkdir -p "$tmp/artifacts/c-reuse"
cat > "$tmp/artifacts/c-reuse/result.json" <<JSON
{"schemaVersion":1,"key":"c--arm64-v8a--apk","version":"1.9","inputId":"input-c-old","target":"C","arch":"arm64-v8a","mode":"apk","reused":true,"sourceAssetId":888,"assetName":"c-v1.9.apk","sha256":"$oldsha"}
JSON
PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/fake/state.json" python3 "$root/scripts/publish_release.py" \
  --plan "$tmp/plan-fallback.json" --state "$tmp/state-fallback.json" --artifacts "$tmp/artifacts" --output-dir "$tmp/out-fallback"
[ "$(jq -r .complete "$tmp/out-fallback/build-state.json")" = true ]
[ "$(jq -r '.fallback["c--arm64-v8a--apk"].version' "$tmp/out-fallback/build-state.json")" = 1.9 ]
[ "$(jq -r '.variants["c--arm64-v8a--apk"].version' "$tmp/out-fallback/build-state.json")" = 1.9 ]
[ "$(jq '[.releases["8"].assets[]|select(.name=="c-v1.9.apk")]|length' "$tmp/fake/state.json")" -eq 1 ]
echo "release publisher compatible-fallback reuse test passed"
