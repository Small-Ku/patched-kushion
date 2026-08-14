#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, shutil
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--key', required=True); p.add_argument('--input-id', required=True)
p.add_argument('--target', required=True); p.add_argument('--arch', required=True); p.add_argument('--mode', choices=['apk','module'], required=True); p.add_argument('--version', required=True)
p.add_argument('--build-dir', type=Path, default=Path('build')); p.add_argument('--build-log', type=Path, default=Path('build.md'))
p.add_argument('--output-dir', type=Path, required=True)
a=p.parse_args()
pattern='*.apk' if a.mode=='apk' else '*.zip'
outputs=sorted(a.build_dir.glob(pattern))
skip_file=a.build_dir/'skip.json'
if not outputs and skip_file.is_file():
    try:
        skip=json.loads(skip_file.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid optional variant skip marker: {exc}")
    a.output_dir.mkdir(parents=True, exist_ok=True)
    result={
        'schemaVersion':1,'key':a.key,'inputId':a.input_id,'target':a.target,'arch':a.arch,'mode':a.mode,'version':a.version,
        'skipped':True,'reason':str(skip.get('reason','stock variant unavailable')),
    }
    (a.output_dir/'result.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    raise SystemExit(0)
if len(outputs)!=1:
    raise SystemExit(f"expected exactly one {pattern} output for {a.key}, found {len(outputs)}: {[x.name for x in outputs]}")
out=outputs[0]
h=hashlib.sha256()
with out.open('rb') as f:
    for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
a.output_dir.mkdir(parents=True, exist_ok=True)
copy=a.output_dir/out.name
shutil.copyfile(out, copy)
result={
    'schemaVersion':1,'key':a.key,'inputId':a.input_id,'target':a.target,'arch':a.arch,'mode':a.mode,'version':a.version,
    'assetName':out.name,'sha256':h.hexdigest().upper(),'buildLog': a.build_log.read_text() if a.build_log.exists() else ''
}
(a.output_dir/'result.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
