#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
source utils.sh
primary=$'Name: Clone app\nName: GmsCore support'
bundle_listing='Name: KouPhotos distribution identity'
[ "$(select_auxiliary_identity_patch apk KouPhotos "$primary" "$bundle_listing")" = 'KouPhotos distribution identity' ]
[ "$(select_auxiliary_identity_patch module KouPhotos "$primary" "$bundle_listing")" = '' ]
! select_auxiliary_identity_patch apk KouPhotos "$primary" 'Name: Clone app' >/dev/null 2>&1
[ "$(select_auxiliary_identity_patch apk KouTube "$primary" 'Name: Clone app')" = '' ]
[ "$(select_auxiliary_identity_patch apk Other 'Name: Feature' 'Name: Clone app')" = 'Clone app' ]
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
patch_apk() { printf '%s\n' "$3" > "$tmp/options"; }
apply_auxiliary_package_identity input output de.kwoo.shion.photos 'KouPhotos distribution identity' cli kushion-patches.mpp
[ "$(cat "$tmp/options")" = '--exclusive -e "KouPhotos distribution identity" -OtargetPackage=de.kwoo.shion.photos -OupstreamPackage=com.google.android.apps.photos' ]
python3 - <<'PY'
import json, sys, tempfile, tomllib
from pathlib import Path
sys.path.insert(0, 'scripts')
import kushion_patches as kushion
from pipeline_plan import patch_profile_hash, sha_json
from validate_photos_identity import parse_xmltree, validate
config = tomllib.loads(Path('config.toml').read_text())['apps']['KouPhotos']['build']
assert config['identity-patches-source'] == 'in-repo'
assert kushion.planned_identity('KouTube', {}, None) is None
assert kushion.planned_identity('KouPhotos', config, None)['kind'] == 'in-repo'
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    bundle = root / kushion.BUNDLE
    bundle.write_bytes(b'kushion-mpp-one')
    one = kushion.bundle_identity(bundle)
    (root/'kushion-patches.json').write_text(json.dumps(one))
    assert kushion.verify(root, one) == one
    bundle.write_bytes(b'kushion-mpp-two')
    two = kushion.bundle_identity(bundle)
    try: kushion.verify(root)
    except SystemExit: pass
    else: raise AssertionError('tampered MPP accepted')
    assert sha_json({'identityPatches': one}) != sha_json({'identityPatches': two})
    assert patch_profile_hash(config, {}, one, {}, 'apk', 'de.kwoo.shion.photos') != patch_profile_hash(config, {}, two, {}, 'apk', 'de.kwoo.shion.photos')
    assert patch_profile_hash(config, {}, one, {}, 'module', '') == patch_profile_hash(config, {}, two, {}, 'module', '')
    source = root/'source'; source.mkdir()
    file = source/'patch.kt'; file.write_text('one')
    first = kushion.source_digest(source)
    file.write_text('two')
    assert first != kushion.source_digest(source)
    second = kushion.source_digest(source)
    (source/'build').mkdir(); (source/'build'/'output.mpp').write_bytes(b'generated')
    assert kushion.source_digest(source) == second
correct = '''E: manifest (line=1)
  A: package="de.kwoo.shion.photos" (Raw: "de.kwoo.shion.photos")
  E: application (line=2)
    E: provider (line=3)
      A: android:name(0x01010003)="com.google.android.libraries.photos.api.mars.MarsStoreProvider" (Raw: "com.google.android.libraries.photos.api.mars.MarsStoreProvider")
      A: android:authorities(0x01010018)="de.kwoo.shion.photos.api.mars" (Raw: "de.kwoo.shion.photos.api.mars")
    E: activity (line=4)
      E: intent-filter (line=5)
        E: data (line=6)
          A: android:host(0x01010028)="de.kwoo.shion.photos.api.mars" (Raw: "de.kwoo.shion.photos.api.mars")
    E: meta-data (line=7)
      A: android:name(0x01010003)="app.revanced.android.gms.SPOOFED_PACKAGE_NAME"
'''
validate(parse_xmltree(correct))
validate(parse_xmltree(correct.replace('android:', 'http://schemas.android.com/apk/res/android:')))
for wrong in ('app.revanced.android.apps.photos.api.mars', 'com.google.android.libraries.photos.api.mars', 'app.morphe.android.apps.photos.api.mars'):
    for occurrence in ('authorities', 'host'):
        bad = correct.replace(f'android:{occurrence}(0x010100' + ('18' if occurrence == 'authorities' else '28') + ')="de.kwoo.shion.photos.api.mars"', f'android:{occurrence}="{wrong}"')
        try: validate(parse_xmltree(bad))
        except ValueError: pass
        else: raise AssertionError(f'colliding {occurrence} accepted')
for bad in ('', correct.replace('E: intent-filter', 'E: unrelated'), correct.replace('A: package="de.kwoo.shion.photos"', 'A: package="other.app"')):
    try: validate(parse_xmltree(bad))
    except ValueError: pass
    else: raise AssertionError('missing/incorrect contract accepted')
pipeline = Path('.github/workflows/pipeline.yml').read_text()
assert pipeline.count('bash scripts/build-kushion-patches.sh') == 1
assert pipeline.index('Build Kushion Patches') < pipeline.index('Create Build Plan')
assert '--kushion-patches "$RUNNER_TEMP/kushion-patches/kushion-patches.json"' in pipeline
arch = Path('.github/workflows/build-arch.yml').read_text()
assert 'Download Kushion Patches' in arch and 'Verify Planned Kushion Patches' in arch
assert 'scripts/build-kushion-patches.sh' not in arch
assert 'matrix.variant.mode == \'apk\'' in arch
assert 'version "1.3.4"' in Path('kushion-patches/settings.gradle.kts').read_text()
assert 'projectsPath = null' in Path('kushion-patches/settings.gradle.kts').read_text()
assert 'manifest.attributes["Timestamp"] = "0"' in Path('kushion-patches/patches/build.gradle.kts').read_text()
assert 'export ANDROID_HOME="$output/no-platform-sdk"' in Path('scripts/build-kushion-patches.sh').read_text()
assert 'export JAVA_HOME="$CONDA_PREFIX"' in Path('scripts/build-kushion-patches.sh').read_text()
assert not Path('settings.gradle.kts').exists()
PY
echo 'Kushion Patches selection, handoff, hashing and validator tests passed'
