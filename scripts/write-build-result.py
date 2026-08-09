#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--key', required=True); p.add_argument('--input-id', required=True)
p.add_argument('--target', required=True); p.add_argument('--arch', required=True); p.add_argument('--mode', choices=['apk','module'], required=True)
p.add_argument('--build-dir', type=Path, default=Path('build')); p.add_argument('--build-log', type=Path, default=Path('build.md'))
p.add_argument('--output-dir', type=Path, required=True)
a=p.parse_args()
pattern='*.apk' if a.mode=='apk' else '*.zip'
outputs=sorted(a.build_dir.glob(pattern))
if len(outputs)!=1:
    raise SystemExit(f"expected exactly one {pattern} output for {a.key}, found {len(outputs)}: {[x.name for x in outputs]}")
out=outputs[0]
h=hashlib.sha256()
with out.open('rb') as f:
    for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
a.output_dir.mkdir(parents=True, exist_ok=True)
copy=a.output_dir/out.name
copy.write_bytes(out.read_bytes())
result={
    'schemaVersion':1,'key':a.key,'inputId':a.input_id,'target':a.target,'arch':a.arch,'mode':a.mode,
    'assetName':out.name,'sha256':h.hexdigest().upper(),'buildLog': a.build_log.read_text() if a.build_log.exists() else ''
}
(a.output_dir/'result.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
