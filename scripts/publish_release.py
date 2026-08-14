#!/usr/bin/env python3
"""Publish successful build results to a reusable GitHub Release."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile
from typing import Any

SCHEMA_VERSION = 1


def run(args: list[str], *, stdout=None) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=False, stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE, text=stdout is None)


def check(args: list[str]) -> str:
    proc = run(args)
    if proc.returncode:
        detail = proc.stderr.strip() if isinstance(proc.stderr, str) else str(proc.stderr)
        raise SystemExit(f"{' '.join(args)} failed: {detail}")
    return proc.stdout if isinstance(proc.stdout, str) else ""


def gh_json(endpoint: str) -> Any:
    out = check(["gh", "api", endpoint])
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid GitHub JSON for {endpoint}: {exc}")


def load_json(path: Path, default: Any) -> Any:
    if not path.exists(): return default
    try: return json.loads(path.read_text())
    except json.JSONDecodeError as exc: raise SystemExit(f"invalid JSON in {path}: {exc}")


def download_asset(repository: str, asset_id: int, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('wb') as f:
        proc = subprocess.run(
            ["gh", "api", "-H", "Accept: application/octet-stream", f"repos/{repository}/releases/assets/{asset_id}"],
            check=False, stdout=f, stderr=subprocess.PIPE,
        )
    if proc.returncode:
        raise SystemExit(f"failed to download prior asset {asset_id}: {proc.stderr.decode(errors='replace').strip()}")


def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest().upper()


def load_results(root: Path) -> dict[str, tuple[dict[str, Any], Path | None]]:
    results: dict[str, tuple[dict[str, Any], Path | None]] = {}
    if not root.exists(): return results
    for path in root.rglob('result.json'):
        row=load_json(path,{})
        if not isinstance(row,dict) or row.get('schemaVersion') != 1: raise SystemExit(f"invalid build result {path}")
        key=str(row.get('key',''))
        if not key or key in results: raise SystemExit(f"invalid or duplicate build result {path}")
        if row.get('skipped') is True or row.get('reused') is True:
            results[key]=(row,None)
            continue
        asset=path.parent/str(row.get('assetName',''))
        if not asset.is_file(): raise SystemExit(f"invalid build result asset {path}")
        if sha256(asset) != str(row.get('sha256','')).upper(): raise SystemExit(f"build result digest mismatch: {asset}")
        results[key]=(row,asset)
    return results


def release_exists(repository: str, tag: str) -> bool:
    proc=run(["gh","release","view",tag,"--repo",repository])
    return proc.returncode == 0


def release_assets(repository: str, tag: str) -> dict[str, dict[str, Any]]:
    rel=gh_json(f"repos/{repository}/releases/tags/{tag}")
    result={}
    for asset in rel.get('assets',[]):
        if isinstance(asset,dict) and isinstance(asset.get('name'),str): result[asset['name']]=asset
    return result


def accepted_input_id(item: dict[str, Any], version: str) -> str | None:
    candidates=item.get('candidateInputIds')
    if isinstance(candidates,dict):
        value=candidates.get(version)
        return str(value) if value else None
    if version == str(item.get('version','')):
        return str(item.get('inputId','')) or None
    return None


def variant_is_compatible(item: dict[str, Any], state: dict[str, Any]) -> bool:
    version=str(state.get('version') or item.get('version',''))
    expected=accepted_input_id(item,version)
    return bool(expected and state.get('inputId') == expected and isinstance(state.get('assetId'),int))


def write_module_updates(repository: str, tag: str, desired_by_key: dict[str, dict[str,Any]], variants: dict[str,Any], outdir: Path, cache: Path) -> None:
    if not tag.isdigit(): return
    for key,item in sorted(desired_by_key.items()):
        if item.get('mode') != 'module': continue
        state=variants.get(key)
        if (
            not isinstance(state,dict)
            or not variant_is_compatible(item,state)
        ): continue
        asset_name=str(state.get('assetName',''))
        local=cache/asset_name
        if not local.exists(): download_asset(repository,int(state['assetId']),local)
        try:
            with zipfile.ZipFile(local) as z:
                prop=z.read('module.prop').decode(errors='replace')
        except (zipfile.BadZipFile, KeyError) as exc:
            raise SystemExit(f"could not inspect module.prop in {asset_name}: {exc}")
        values={}
        for line in prop.splitlines():
            if '=' in line:
                k,v=line.split('=',1); values[k]=v
        update=values.get('updateJson','')
        if not update: continue
        filename=Path(update).name
        if not filename.endswith('-update.json'): continue
        version=values.get('version','')
        payload={
            'version':version,
            'versionCode':int(tag),
            'zipUrl':f"https://github.com/{repository}/releases/download/{tag}/{asset_name}",
            'changelog':f"https://raw.githubusercontent.com/{repository}/update/build.md",
        }
        (outdir/filename).write_text(json.dumps(payload,indent=2)+"\n")


def main() -> None:
    p=argparse.ArgumentParser()
    p.add_argument('--plan',type=Path,required=True); p.add_argument('--state',type=Path,required=True)
    p.add_argument('--artifacts',type=Path,required=True); p.add_argument('--output-dir',type=Path,required=True)
    a=p.parse_args()
    plan=load_json(a.plan,{})
    if not isinstance(plan,dict) or plan.get('schemaVersion') != 1: raise SystemExit('unsupported plan schema')
    repository=str(plan.get('repository','')); tag=str(plan.get('releaseTag','')); generation=str(plan.get('generation',''))
    if not repository or not tag or not generation: raise SystemExit('incomplete plan')
    state=load_json(a.state,{"schemaVersion":1,"variants":{}})
    if not isinstance(state,dict) or state.get('schemaVersion') != 1 or not isinstance(state.get('variants'),dict):
        raise SystemExit('unsupported build state')
    previous=dict(state.get('variants',{}))
    desired={str(x['key']):x for x in plan.get('desired',[]) if isinstance(x,dict) and x.get('key')}
    results=load_results(a.artifacts)
    for key,(row,_asset) in results.items():
        item=desired.get(key)
        version=str(row.get('version') or item.get('version','') if item else '')
        expected=accepted_input_id(item,version) if item is not None else None
        if item is None or not expected or row.get('inputId') != expected:
            raise SystemExit(f"build result does not match the current plan: {key}")
        if row.get('skipped') is True and not item.get('optional'):
            raise SystemExit(f"required build variant was incorrectly reported as skipped: {key}")
        if row.get('reused') is True and not isinstance(row.get('sourceAssetId'),int):
            raise SystemExit(f"reused build result has no source asset: {key}")

    successful={key:value for key,value in results.items() if value[0].get('skipped') is not True}
    skipped={key:value[0] for key,value in results.items() if value[0].get('skipped') is True}

    same_release=state.get('generation') == generation and str(state.get('releaseTag','')) == tag
    if not successful and not same_release and not previous:
        print('No successful build results exist. Keep the current build state.')
        a.output_dir.mkdir(parents=True,exist_ok=True)
        (a.output_dir/'reconciled.json').write_text(json.dumps(state,indent=2,sort_keys=True)+'\n')
        return

    a.output_dir.mkdir(parents=True,exist_ok=True)
    cache=a.output_dir/'assets'; cache.mkdir(exist_ok=True)
    marker=f"<!-- patched-kushion-generation:{generation} -->"
    existed = release_exists(repository,tag)
    if not existed:
        check(["gh","release","create",tag,"--repo",repository,"--title","Release", "--notes", f"{marker}\nBuild publication is in progress."])
    existing_before = release_assets(repository, tag)

    # A new generation receives previous known-good variants as fallbacks. They
    # remain unsatisfied if their inputId is stale, so the planner retries them.
    if not same_release:
        for key,item in desired.items():
            if key in successful: continue
            old=previous.get(key)
            if not isinstance(old,dict) or not isinstance(old.get('assetId'),int) or not old.get('assetName'): continue
            if str(old['assetName']) in existing_before:
                continue
            local=cache/str(old['assetName'])
            download_asset(repository,int(old['assetId']),local)
            check(["gh","release","upload",tag,str(local),"--repo",repository,"--clobber"])

    for key,(row,asset) in sorted(successful.items()):
        asset_name=str(row.get('assetName',''))
        if not asset_name:
            raise SystemExit(f"successful build result has no asset name: {key}")
        if row.get('reused') is True:
            if asset_name not in release_assets(repository,tag):
                local=cache/asset_name
                download_asset(repository,int(row['sourceAssetId']),local)
                if row.get('sha256') and sha256(local) != str(row['sha256']).upper():
                    raise SystemExit(f"reused build result digest mismatch: {key}")
                check(["gh","release","upload",tag,str(local),"--repo",repository,"--clobber"])
            continue
        assert asset is not None
        check(["gh","release","upload",tag,str(asset),"--repo",repository,"--clobber"])
        shutil.copyfile(asset,cache/asset.name)

    assets=release_assets(repository,tag)
    new_variants: dict[str,Any] = {}
    for key,item in desired.items():
        old=previous.get(key)
        if key in successful:
            row,_=successful[key]
            asset=assets.get(str(row['assetName']))
            if not asset or not isinstance(asset.get('id'),int): raise SystemExit(f"uploaded release asset missing: {row['assetName']}")
            new_variants[key]={
                'inputId':row['inputId'],'target':item['target'],'arch':item['arch'],'mode':item['mode'],
                'version':str(row.get('version') or item.get('version','')),
                'assetId':asset['id'],'assetName':row['assetName'],'sha256':row['sha256'],'releaseTag':tag,
            }
        elif isinstance(old,dict) and old.get('assetName') in assets:
            copied=assets[str(old['assetName'])]
            new_variants[key]={**old,'assetId':copied['id'],'assetName':copied['name'],'releaseTag':tag}
        elif same_release and isinstance(old,dict):
            new_variants[key]=old

    satisfied=[]; fallback=[]; unavailable=[]; pending=[]
    for key,item in desired.items():
        row=new_variants.get(key,{})
        if row.get('inputId') == item.get('inputId') and row.get('assetId'):
            satisfied.append(key)
        elif isinstance(row,dict) and variant_is_compatible(item,row):
            fallback.append(key)
        elif item.get('optional') and key in skipped:
            unavailable.append(key)
        else:
            pending.append(key)
    new_state={
        'schemaVersion':1,'generation':generation,'releaseTag':tag,
        'complete':not pending,'variants':new_variants,
        'fallback':{key:{'version':new_variants[key].get('version',''),'inputId':new_variants[key].get('inputId','')} for key in fallback},
        'unavailable':{
            key:{'inputId':desired[key]['inputId'],'reason':str(skipped[key].get('reason','stock variant unavailable'))}
            for key in unavailable
        },
    }
    (a.output_dir/'build-state.json').write_text(json.dumps(new_state,indent=2,sort_keys=True)+'\n')
    # compatibility output name used when no release was possible
    (a.output_dir/'reconciled.json').write_text(json.dumps(new_state,indent=2,sort_keys=True)+'\n')

    lines=[marker,f"# Release {tag}","",f"Generation: `{generation}`","","## Confirmed variants",""]
    lines += [f"- {key}" for key in satisfied] or ["- None"]
    lines += ["","## Compatible fallback variants",""]
    lines += [f"- {key}: `{new_variants[key].get('version','')}`" for key in fallback] or ["- None"]
    lines += ["","## Auto variants unavailable from current stock sources",""]
    lines += [f"- {key}: {skipped[key].get('reason','stock variant unavailable')}" for key in unavailable] or ["- None"]
    lines += ["","## Pending retry",""] + ([f"- {key}" for key in pending] or ["- None"])
    if successful:
        lines += ["","## This run",""]
        for key,(row,_) in sorted(successful.items()):
            lines.append(f"- {key}: `{row['assetName']}`")
    (a.output_dir/'build.md').write_text("\n".join(lines)+"\n")

    write_module_updates(repository,tag,desired,new_variants,a.output_dir,cache)
    release_state_asset=a.output_dir/'patched-kushion-build-state.json'
    shutil.copyfile(a.output_dir/'build-state.json', release_state_asset)
    check(["gh","release","upload",tag,str(release_state_asset),"--repo",repository,"--clobber"])
    check(["gh","release","edit",tag,"--repo",repository,"--notes-file",str(a.output_dir/'build.md')])
    print(f"release_tag={tag}")
    print(f"satisfied={len(satisfied)}")
    print(f"fallback={len(fallback)}")
    print(f"unavailable={len(unavailable)}")
    print(f"pending={len(pending)}")

if __name__=='__main__': main()
