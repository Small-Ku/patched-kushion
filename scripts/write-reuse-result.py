#!/usr/bin/env python3
from __future__ import annotations
import argparse, json
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--variant-json', required=True)
p.add_argument('--version', required=True)
p.add_argument('--target', required=True)
p.add_argument('--arch', required=True)
p.add_argument('--output-dir', type=Path, required=True)
a=p.parse_args()
variant=json.loads(a.variant_json)
reuse=variant.get('reuse') if isinstance(variant,dict) else None
candidate_ids=variant.get('candidateInputIds',{}) if isinstance(variant,dict) else {}
if not isinstance(reuse,dict) or reuse.get('version') != a.version:
    raise SystemExit('selected version is not reusable for this variant')
input_id=candidate_ids.get(a.version)
if not input_id or input_id != reuse.get('inputId'):
    raise SystemExit('reusable variant input fingerprint does not match selected version')
asset_id=reuse.get('assetId')
asset_name=reuse.get('assetName')
if not isinstance(asset_id,int) or not asset_name:
    raise SystemExit('reusable variant has no source release asset')
a.output_dir.mkdir(parents=True,exist_ok=True)
result={
    'schemaVersion':1,'key':variant['key'],'inputId':input_id,'target':a.target,
    'arch':a.arch,'mode':variant['mode'],'version':a.version,'reused':True,
    'sourceAssetId':asset_id,'assetName':asset_name,'sha256':str(reuse.get('sha256','')).upper(),
    'sourceReleaseTag':str(reuse.get('releaseTag','')),
}
(a.output_dir/'result.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
