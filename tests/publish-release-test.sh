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
    r['assets'].append({'id':aid,'name':path.name,'size':path.stat().st_size}); save(); sys.exit(0)
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
[ "$(jq -r .complete "$tmp/out1/publication-status.json")" = true ]
[ "$(jq -r .publishedAssetCount "$tmp/out1/publication-status.json")" -eq 1 ]
[ "$(jq -r .repository "$tmp/out1/published-assets.json")" = example/patched-kushion ]
[ "$(jq -r .releaseTag "$tmp/out1/published-assets.json")" = 7 ]
[ "$(jq -r '.assets[0].assetName' "$tmp/out1/published-assets.json")" = a.apk ]
[ "$(jq -r '.assets[0].size' "$tmp/out1/published-assets.json")" -eq 5 ]

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
[ "$(jq -r '.assets[0].assetName' "$tmp/out2/published-assets.json")" = b.apk ]
[ "$(jq -r '.assets[0].size' "$tmp/out2/published-assets.json")" -eq 5 ]
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

# Publication consistency holds new target/global results until every required
# peer is either newly successful or backed by a compatible previous asset.
python3 - "$root/scripts/publish_release.py" <<'PY_ATOMICITY'
import importlib.util, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('publish_release',sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
desired={
 't--a--apk':{'key':'t--a--apk','target':'T','arch':'a','mode':'apk','inputId':'new-a','optional':False,'publishConsistency':'target'},
 't--b--apk':{'key':'t--b--apk','target':'T','arch':'b','mode':'apk','inputId':'new-b','candidateInputIds':{'1':'old-b','2':'new-b'},'optional':False,'publishConsistency':'target'},
}
success={'t--a--apk':({'inputId':'new-a'},None)}
allowed,held=mod.apply_publication_consistency(desired,success,{}, {})
assert not allowed and 't--a--apk' in held
previous={'t--b--apk':{'inputId':'old-b','version':'1','assetId':12,'assetName':'b.apk'}}
allowed,held=mod.apply_publication_consistency(desired,success,{},previous)
assert 't--a--apk' in allowed and not held

global_desired={
 **desired,
 'g--a--apk':{'key':'g--a--apk','target':'G','arch':'a','mode':'apk','inputId':'g-a','optional':False,'publishConsistency':'global'},
 'g--b--apk':{'key':'g--b--apk','target':'G','arch':'b','mode':'apk','inputId':'g-b','optional':False,'publishConsistency':'global'},
}
global_success={'g--a--apk':({'inputId':'g-a'},None)}
allowed,held=mod.apply_publication_consistency(global_desired,global_success,{},previous)
assert not allowed and held.get('g--a--apk') == 'global publication group is incomplete'

# A single-ABI payload must never be published again under the universal axis.
# Auto variants may drop the bogus universal result; explicit universal outputs
# fail closed because silently changing their requirement would hide corruption.
alias_desired={
 'p--universal--apk':{'key':'p--universal--apk','target':'P','arch':'universal','mode':'apk','optional':True},
 'p--arm64-v8a--apk':{'key':'p--arm64-v8a--apk','target':'P','arch':'arm64-v8a','mode':'apk','optional':True},
}
alias_success={
 'p--universal--apk':({'key':'p--universal--apk','target':'P','version':'1','arch':'universal','mode':'apk','sha256':'SAME'},Path('u.apk')),
 'p--arm64-v8a--apk':({'key':'p--arm64-v8a--apk','target':'P','version':'1','arch':'arm64-v8a','mode':'apk','sha256':'SAME'},Path('a.apk')),
}
allowed,alias_skipped=mod.reject_aliased_universal_results(alias_desired,alias_success,{})
assert set(allowed)=={'p--arm64-v8a--apk'}
assert alias_skipped['p--universal--apk']['skipped'] is True
assert 'byte-identical to arm64-v8a' in alias_skipped['p--universal--apk']['reason']
alias_desired['p--universal--apk']['optional']=False
try:
    mod.reject_aliased_universal_results(alias_desired,alias_success,{})
except SystemExit as exc:
    assert 'invalid required universal artifact' in str(exc)
else:
    raise AssertionError('required aliased universal result was not rejected')
# Pending publication details select the candidate that reached the furthest
# stage, not merely the earliest traversal node.
pending_desired={
 'p--arm64--apk':{'key':'p--arm64--apk','target':'P','version':'1.0','arch':'arm64-v8a','mode':'apk','optional':False},
}
failed={
 'one':{'variantKey':'p--arm64--apk','version':'1.1','compatibility':'forward-probe','traversalIndex':1,'stage':'stock','category':'stock-failed','failureClass':'tooling','reason':'stock failed'},
 'two':{'variantKey':'p--arm64--apk','version':'1.2','compatibility':'forward-probe','traversalIndex':2,'stage':'patch','category':'patch-incompatible','failureClass':'compatibility','reason':'fingerprint missing'},
}
detail=mod.pending_details({'p--arm64--apk'},pending_desired,failed,{})[0]
assert detail['attemptedVersion']=='1.2'
assert detail['category']=='patch-incompatible'
assert detail['failureClass']=='compatibility'
assert detail['attempts'][0]['version']=='1.2'
print('publication consistency, universal-alias, and pending-progress unit tests passed')
PY_ATOMICITY

# Multiple compatible upstream versions may be published together. The newest
# successful version becomes the preferred state entry, while every successful
# input remains in the reuse ledger so a later scheduled run does not repatch it.
rm -rf "$tmp/artifacts"; mkdir -p "$tmp/artifacts/d20" "$tmp/artifacts/d21"
forward_input=$(python3 - <<'PY_HASH'
import hashlib, json
value={"base":"base-d","version":"2.1","arch":"universal","mode":"apk"}
raw=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
print(hashlib.sha256(raw).hexdigest())
PY_HASH
)
cat > "$tmp/plan-multi.json" <<'JSON'
{
  "schemaVersion":1,"repository":"example/patched-kushion","generation":"gen3","releaseTag":"9",
  "desired":[
    {"key":"d--universal--apk","target":"D","arch":"universal","mode":"apk","version":"2.0","inputId":"input-d20","candidateInputIds":{"2.0":"input-d20"},"inputBase":"base-d","forwardProbeLimit":2,"optional":false}
  ],
  "matrix":[]
}
JSON
printf 'apk-d-2.0' > "$tmp/artifacts/d20/d-2.0.apk"
printf 'apk-d-2.1' > "$tmp/artifacts/d21/d-2.1.apk"
sha20=$(sha256sum "$tmp/artifacts/d20/d-2.0.apk"|awk '{print toupper($1)}')
sha21=$(sha256sum "$tmp/artifacts/d21/d-2.1.apk"|awk '{print toupper($1)}')
cat > "$tmp/artifacts/d20/result.json" <<JSON
{"schemaVersion":1,"key":"d--universal--apk--2.0","variantKey":"d--universal--apk","version":"2.0","inputId":"input-d20","target":"D","arch":"universal","mode":"apk","assetName":"d-2.0.apk","sha256":"$sha20","buildLog":""}
JSON
cat > "$tmp/artifacts/d21/result.json" <<JSON
{"schemaVersion":1,"key":"d--universal--apk--2.1","variantKey":"d--universal--apk","version":"2.1","inputId":"$forward_input","target":"D","arch":"universal","mode":"apk","assetName":"d-2.1.apk","sha256":"$sha21","buildLog":""}
JSON
printf '%s\n' '{"schemaVersion":1,"variants":{}}' > "$tmp/state-multi.json"
PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/fake/state.json" python3 "$root/scripts/publish_release.py" \
  --plan "$tmp/plan-multi.json" --state "$tmp/state-multi.json" --artifacts "$tmp/artifacts" --output-dir "$tmp/out-multi"
[ "$(jq -r '.variants["d--universal--apk"].version' "$tmp/out-multi/build-state.json")" = 2.1 ]
[ "$(jq -r '.variants["d--universal--apk"].compatibility' "$tmp/out-multi/build-state.json")" = forward-compatible ]
[ "$(jq '.artifactsByInputId|length' "$tmp/out-multi/build-state.json")" -eq 2 ]
[ "$(jq -r --arg input "$forward_input" '.artifactsByInputId[$input].version' "$tmp/out-multi/build-state.json")" = 2.1 ]
[ "$(jq '[.releases["9"].assets[]|select(.name=="d-2.0.apk" or .name=="d-2.1.apk")]|length' "$tmp/fake/state.json")" -eq 2 ]
echo "release publisher multi-version ledger test passed"

# A completely failed new generation must not advance the release or overwrite
# the durable update-branch state with an all-pending checkpoint. Old assets may
# only be carried forward once at least one result proves the new generation.
cat > "$tmp/plan-empty-new-generation.json" <<'JSON'
{
  "schemaVersion":1,"repository":"example/patched-kushion","generation":"gen4","releaseTag":"10",
  "desired":[
    {"key":"e--arm64-v8a--apk","target":"E","arch":"arm64-v8a","mode":"apk","version":"3.0","inputId":"input-e-new","optional":false}
  ],
  "matrix":[]
}
JSON
cat > "$tmp/state-empty-new-generation.json" <<'JSON'
{"schemaVersion":1,"generation":"gen3","releaseTag":"9","variants":{"e--arm64-v8a--apk":{"version":"2.9","inputId":"input-e-old","assetId":700,"assetName":"e-v2.9.apk","sha256":"OLD","releaseTag":"9"}}}
JSON
rm -rf "$tmp/artifacts"; mkdir -p "$tmp/artifacts"
PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/fake/state.json" python3 "$root/scripts/publish_release.py" \
  --plan "$tmp/plan-empty-new-generation.json" --state "$tmp/state-empty-new-generation.json" --artifacts "$tmp/artifacts" --output-dir "$tmp/out-empty-new-generation"
[ ! -e "$tmp/out-empty-new-generation/build-state.json" ]
[ "$(jq 'has("10")' "$tmp/fake/state.json")" = false ]
[ "$(jq -r .generation "$tmp/out-empty-new-generation/reconciled.json")" = gen3 ]
[ "$(jq -r .complete "$tmp/out-empty-new-generation/publication-status.json")" = false ]
[ "$(jq -r '.pending[0]' "$tmp/out-empty-new-generation/publication-status.json")" = e--arm64-v8a--apk ]
[ "$(jq '.assets|length' "$tmp/out-empty-new-generation/published-assets.json")" -eq 0 ]
echo "release publisher failed-generation state preservation test passed"
