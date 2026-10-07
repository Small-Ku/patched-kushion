"""Minimal split composition must prove topology and resource fallback."""
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import stock_bundle as bundle


def manifest(split="", code=123, package="com.example", extra="", app_extra=""):
    return f'''N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=1)
    A: http://schemas.android.com/apk/res/android:versionCode(0x0101021b)={code}
    A: http://schemas.android.com/apk/res/android:versionName(0x0101021c)="1.0" (Raw: "1.0")
    A: package="{package}" (Raw: "{package}")
{f'    A: split="{split}" (Raw: "{split}")' if split else ''}
{extra}
      E: application (line=2)
        A: http://schemas.android.com/apk/res/android:hasCode(0x0101000c)={'true' if not split else 'false'}
{app_extra}
'''


def resources(configs):
    return 'Binary APK\nPackage name=com.example id=7f\n' + '\n'.join(
        f'    resource {resource} string/item_{resource}\n' + '\n'.join(
            f'      ({config}) "fixture"' for config in variants)
        for resource, variants in configs.items()) + '\n'


class MinimalStandaloneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'signed'
        self.source.mkdir()
        self.output = self.root / 'minimal'
        self.dumps = {}
        self.add('base.apk', '', {'0x7f010001': ['']})
        self.add('arm64.apk', 'config.arm64_v8a', libs=['arm64-v8a'])
        self.add('mdpi.apk', 'config.mdpi', {'0x7f010002': ['mdpi-v4']}, padding=3)
        self.add('xxhdpi.apk', 'config.xxhdpi', {'0x7f010002': ['xxhdpi-v4']}, padding=300)
        self.add('en.apk', 'config.en', {'0x7f010001': ['en']})
        self.add('fr.apk', 'config.fr', {'0x7f010001': ['fr']})
        self.original = {path.name: path.read_bytes() for path in self.source.iterdir()}

    def add(self, name, split, configs=None, libs=(), padding=0, extra='', app_extra='', code=123, package='com.example', payload=None):
        path = self.source / name
        with zipfile.ZipFile(path, 'w') as apk:
            apk.writestr('AndroidManifest.xml', b'manifest')
            if configs:
                apk.writestr('resources.arsc', b'table')
                apk.writestr('res/item', b'resource' + b'x' * padding)
            for abi in libs:
                apk.writestr(f'lib/{abi}/libfixture.so', b'native')
            for member, value in (payload or {}).items():
                apk.writestr(member, value)
        self.dumps[name] = {'xmltree': manifest(split, code, package, extra, app_extra),
                            'resources': resources(configs or {})}

    def select(self):
        def dump(_tool, path, command, *options):
            return self.dumps[path.name][command]
        with patch.object(bundle, 'run_aapt2', side_effect=dump):
            return bundle.minimal_standalone(self.source, 'arm64-v8a', self.output, 'aapt2')

    def test_minimal_set_preserves_originals_and_version_code(self):
        plan = self.select()
        self.assertEqual({row['member'] for row in plan['selected']}, {'base.apk', 'arm64.apk', 'xxhdpi.apk'})
        self.assertEqual(plan['versionCode'], 123)
        self.assertEqual(plan['versionCodePolicy'], 'preserve-upstream')
        self.assertLess(plan['selectedBytes'], plan['inputBytes'])
        self.assertEqual(self.original, {path.name: path.read_bytes() for path in self.source.iterdir()})
        for row in plan['selected'] + plan['omitted']:
            self.assertEqual(row['sha256'], bundle._sha256(self.source / row['member']))

    def test_foreign_namespace_attribute_does_not_shadow_android_attribute(self):
        xml = manifest(app_extra=(
            '          E: http://schemas.horizonos/sdk:library-uses-horizonos-sdk-supplement (line=3)\n'
            '            A: http://schemas.android.com/apk/res/android:name(0x01010003)="android-name" '
            '(Raw: "android-name")\n'
            '            A: http://schemas.horizonos/sdk:name="vendor-name" (Raw: "vendor-name")'
        ))
        nodes = bundle.manifest_tree(xml)
        fields = next(fields for tag, fields in nodes if tag == 'library-uses-horizonos-sdk-supplement')
        self.assertEqual(fields['name'], 'android-name')
        self.assertEqual(fields['http://schemas.horizonos/sdk:name'], 'vendor-name')

    def test_vending_split_list_resource_is_expected_to_be_sanitized(self):
        metadata = (
            '          E: meta-data (line=0)\n'
            '            A: android:name="com.android.vending.splits" '
            '(Raw: "com.android.vending.splits")\n'
            '            A: android:resource=@0x7f010099'
        )
        self.add('base.apk', '', {'0x7f010001': [''], '0x7f010099': ['']},
                 app_extra=metadata)
        plan = self.select()
        self.assertEqual(plan['sanitizedResourceIds'], ['0x7f010099'])
        self.assertNotIn('0x7f010099', plan['requiredResourceIds'])
        self.assertNotIn('0x7f010099', plan['requiredResourceConfigs'])

    def test_locale_with_unique_resource_ids_is_required(self):
        self.add('fr.apk', 'config.fr', {'0x7f010003': ['fr']})
        self.assertIn('fr.apk', [row['member'] for row in self.select()['selected']])

    def test_single_abi_standalone_container_keeps_existing_path(self):
        for path in self.source.glob('*.apk'):
            path.unlink()
        self.add('original.apk', '', libs=['arm64-v8a'])
        plan = self.select()
        self.assertEqual(plan['strategy'], 'standalone-source')
        self.assertEqual(plan['omitted'], [])
        self.assertEqual(plan['selectedBytes'], plan['inputBytes'])

    def test_base_can_supply_requested_abi_with_config_splits(self):
        (self.source / 'arm64.apk').unlink()
        self.add('base.apk', '', {'0x7f010001': ['']}, libs=['arm64-v8a'])
        plan = self.select()
        self.assertEqual(plan['strategy'], 'minimal-split-standalone')
        self.assertNotIn('arm64.apk', [row['member'] for row in plan['selected']])

    def test_base_with_foreign_or_multiple_abis_fails_closed(self):
        self.add('base.apk', '', {'0x7f010001': ['']}, libs=['arm64-v8a', 'x86'])
        with self.assertRaisesRegex(bundle.BundleError, 'foreign or multiple ABIs'):
            self.select()

    def test_density_coverage_preserves_orthogonal_qualifiers(self):
        self.assertEqual(bundle._configuration_key('ldrtl-xxhdpi', 'density'), 'ldrtl')
        self.assertEqual(bundle._configuration_key('night-xxhdpi', 'density'), 'night')
        self.assertEqual(bundle._configuration_key('anydpi', 'density'), 'anydpi')
        self.assertEqual(bundle._configuration_key('nodpi-v21', 'density'), 'nodpi-v21')
        self.assertEqual(bundle._configuration_key('', 'density'), '')
        self.assertEqual(bundle._configuration_key('xhdpi-v21', 'density'), 'v21')
        with self.assertRaises(bundle.BundleError):
            bundle._configuration_key('night', 'density')

    def test_density_must_cover_all_resources_and_sdk_qualifiers(self):
        self.add('xxhdpi.apk', 'config.xxhdpi', {'0x7f010003': ['xxhdpi-v21']})
        self.assertEqual({row['member'] for row in self.select()['selected']},
                         {'base.apk', 'arm64.apk', 'mdpi.apk', 'xxhdpi.apk'})

    def test_density_is_unnecessary_when_base_has_default_ids(self):
        self.add('base.apk', '', {'0x7f010001': [''], '0x7f010002': ['']})
        self.add('mdpi.apk', 'config.mdpi', {'0x7f010002': ['mdpi']})
        self.add('xxhdpi.apk', 'config.xxhdpi', {'0x7f010002': ['xxhdpi']})
        self.assertEqual({row['dimension'] for row in self.select()['selected']}, {'core', 'abi'})

    def test_base_default_does_not_cover_orthogonal_density_qualifiers(self):
        self.add('base.apk', '', {'0x7f010001': [''], '0x7f010002': ['']})
        for qualifier in ('ldrtl', 'night', 'v21'):
            with self.subTest(qualifier=qualifier):
                self.add('mdpi.apk', 'config.mdpi', {'0x7f010002': ['mdpi', f'mdpi-{qualifier}' if qualifier == 'v21' else f'{qualifier}-mdpi']})
                self.add('xxhdpi.apk', 'config.xxhdpi', {'0x7f010002': ['xxhdpi']})
                self.assertIn('mdpi.apk', [row['member'] for row in self.select()['selected']])

    def test_base_can_cover_matching_orthogonal_density_qualifiers(self):
        self.add('base.apk', '', {'0x7f010001': [''], '0x7f010002': ['', 'night', 'v21']})
        self.add('mdpi.apk', 'config.mdpi', {'0x7f010002': ['night-mdpi', 'mdpi-v21']})
        self.add('xxhdpi.apk', 'config.xxhdpi', {'0x7f010002': ['night-xxhdpi', 'xxhdpi-v21']})
        self.assertEqual({row['dimension'] for row in self.select()['selected']}, {'core', 'abi'})

    def test_special_density_modes_cannot_be_replaced_by_scalable_density(self):
        for mode in ('nodpi', 'anydpi'):
            with self.subTest(mode=mode):
                self.add('mdpi.apk', 'config.mdpi', {'0x7f010002': [mode]})
                self.add('xxhdpi.apk', 'config.xxhdpi', {'0x7f010002': ['xxhdpi']})
                selected = {row['member'] for row in self.select()['selected']}
                self.assertIn('mdpi.apk', selected)
                self.assertIn('xxhdpi.apk', selected)

    def test_special_density_mode_with_base_default_is_still_required(self):
        self.add('base.apk', '', {'0x7f010001': [''], '0x7f010002': ['']})
        self.add('mdpi.apk', 'config.mdpi', {'0x7f010002': ['nodpi']})
        self.add('xxhdpi.apk', 'config.xxhdpi', {'0x7f010002': ['xxhdpi']})
        self.assertIn('mdpi.apk', [row['member'] for row in self.select()['selected']])

    def test_unknown_native_path_in_resource_split_fails_closed(self):
        self.add('fr.apk', 'config.fr', {'0x7f010001': ['fr']},
                 payload={'lib/riscv64/libruntime.so': b'native'})
        with self.assertRaisesRegex(bundle.BundleError, 'pure resource payload'):
            self.select()
        self.assertFalse(self.output.exists())

    def test_unknown_features_dependencies_and_payloads_fail_before_output(self):
        cases = [
            {'split': 'feature.maps'},
            {'split': 'config.en', 'extra': '    A: android:isFeatureSplit(0x0101055b)=true'},
            {'split': 'config.en', 'extra': '    A: configForSplit="maps" (Raw: "maps")'},
            {'split': 'config.en', 'extra': '      E: uses-split (line=2)\n        A: android:name="maps" (Raw: "maps")'},
            {'split': 'config.en', 'payload': {'assets/runtime.bin': b'asset'}},
            {'split': 'config.en', 'payload': {'classes.dex': b'code'}},
            {'split': 'config.en', 'app_extra': '        A: android:hasCode=true'},
            {'split': 'config.mystery'},
            {'split': 'config.en', 'configs': {'0x7f010001': ['en-night']}},
        ]
        for case in cases:
            with self.subTest(case=case):
                args = {'name': 'fr.apk', 'split': 'config.fr', 'configs': {'0x7f010001': ['fr']}}
                args.update(case)
                self.add(**args)
                with self.assertRaises(bundle.BundleError):
                    self.select()
                self.assertFalse(self.output.exists())

    def test_package_version_missing_base_foreign_abi_and_duplicate_ids_fail(self):
        for update in ({'code': 124}, {'package': 'com.foreign'}, {'split': 'config.en'}):
            with self.subTest(update=update):
                args = {'name': 'fr.apk', 'split': 'config.fr', 'configs': {'0x7f010001': ['fr']}}
                args.update(update)
                self.add(**args)
                with self.assertRaises(bundle.BundleError):
                    self.select()
        self.add('fr.apk', 'config.fr', {'0x7f010001': ['fr']})
        self.add('foreign.apk', 'config.x86', libs=['x86'])
        with self.assertRaisesRegex(bundle.BundleError, 'requested-ABI'):
            self.select()
        (self.source / 'foreign.apk').unlink()
        (self.source / 'base.apk').unlink()
        with self.assertRaisesRegex(bundle.BundleError, 'requires base'):
            self.select()

    def test_play_source_stamp_digest_is_inert_but_wrong_shape_fails(self):
        self.add('arm64.apk', 'config.arm64_v8a', libs=['arm64-v8a'],
                 payload={'stamp-cert-sha256': b'x' * 32})
        self.select()
        self.add('arm64.apk', 'config.arm64_v8a', libs=['arm64-v8a'],
                 payload={'stamp-cert-sha256': b'x' * 31})
        with self.assertRaisesRegex(bundle.BundleError, 'unmodeled payload'):
            self.select()

    def test_play_derived_apk_metadata_is_inert_but_other_metadata_fails(self):
        derived = (
            '          E: meta-data (line=0)\n'
            '            A: android:name="com.android.vending.derived.apk.id" '
            '(Raw: "com.android.vending.derived.apk.id")\n'
            '            A: android:value=5'
        )
        self.add('arm64.apk', 'config.arm64_v8a', libs=['arm64-v8a'], app_extra=derived)
        self.select()

        unknown = (
            '          E: meta-data (line=0)\n'
            '            A: android:name="runtime.behavior" (Raw: "runtime.behavior")\n'
            '            A: android:value=5'
        )
        self.add('arm64.apk', 'config.arm64_v8a', libs=['arm64-v8a'], app_extra=unknown)
        with self.assertRaisesRegex(bundle.BundleError, 'unsupported meta-data'):
            self.select()

    def test_required_split_types_retain_otherwise_redundant_configs(self):
        self.add('base.apk', '', {'0x7f010001': ['']}, extra='    A: android:requiredSplitTypes="base__lang" (Raw: "base__lang")')
        self.add('en.apk', 'config.en', {'0x7f010001': ['en']}, extra='    A: android:splitTypes="base__lang" (Raw: "base__lang")')
        plan = self.select()
        self.assertIn('en.apk', [row['member'] for row in plan['selected']])
        self.assertEqual(next(row['reason'] for row in plan['selected'] if row['member'] == 'en.apk'),
                         'manifest-required-split-type')

    def test_missing_required_split_type_fails_closed(self):
        self.add('base.apk', '', {'0x7f010001': ['']}, extra='    A: android:requiredSplitTypes="missing" (Raw: "missing")')
        with self.assertRaisesRegex(bundle.BundleError, 'required split types'):
            self.select()

    def test_config_version_name_can_be_absent_but_cannot_conflict(self):
        self.dumps['fr.apk']['xmltree'] = self.dumps['fr.apk']['xmltree'].replace(
            '    A: http://schemas.android.com/apk/res/android:versionName(0x0101021c)="1.0" (Raw: "1.0")\n', '')
        self.assertEqual(self.select()['versionName'], '1.0')
        self.dumps['fr.apk']['xmltree'] = manifest('config.fr').replace('"1.0"', '"2.0"')
        with self.assertRaisesRegex(bundle.BundleError, 'versionName'):
            self.select()

    def test_minimal_size_estimate_matches_selector_plan(self):
        def dump(_tool, path, command, *options):
            return self.dumps[path.name][command]

        with patch.object(bundle, 'run_aapt2', side_effect=dump):
            plan = bundle.minimal_standalone(
                self.source, 'arm64-v8a', self.output, 'aapt2')
            estimate = bundle.estimate_standalone_size(
                'arm64-v8a',
                selected_dir=self.source,
                aapt2='aapt2',
                policy='minimal',
            )

        self.assertEqual(estimate['estimatedStandaloneBytes'], plan['selectedBytes'])
        self.assertEqual(estimate['sizeEstimateBasis'], 'proven-minimal-splits')
        self.assertEqual(estimate['sizeEstimatePolicy'], 'minimal')
        self.assertTrue(estimate['sizeEstimateEvidence']['minimalProven'])
        self.assertEqual(
            estimate['sizeEstimateEvidence']['selectedSplitCount'],
            len(plan['selected']),
        )
        self.assertEqual(
            estimate['sizeEstimateEvidence']['omittedSplitCount'],
            len(plan['omitted']),
        )

    def test_preserve_size_estimate_does_not_run_minimal_selector(self):
        expected = sum(path.stat().st_size for path in self.source.glob('*.apk'))
        with patch.object(
                bundle, 'minimal_standalone',
                side_effect=AssertionError('minimal selector must not run')):
            estimate = bundle.estimate_standalone_size(
                'arm64-v8a',
                selected_dir=self.source,
                policy='preserve',
            )

        self.assertEqual(estimate['estimatedStandaloneBytes'], expected)
        self.assertEqual(estimate['sizeEstimateBasis'], 'preserve-split-set')
        self.assertEqual(estimate['sizeEstimatePolicy'], 'preserve')
        self.assertFalse(estimate['sizeEstimateEvidence']['minimalProven'])

    def test_minimal_size_estimate_fails_when_selector_proof_fails(self):
        with patch.object(
                bundle, 'minimal_standalone',
                side_effect=bundle.BundleError('proof rejected')):
            with self.assertRaisesRegex(bundle.BundleError, 'proof rejected'):
                bundle.estimate_standalone_size(
                    'arm64-v8a',
                    selected_dir=self.source,
                    aapt2='aapt2',
                    policy='minimal',
                )

    def test_minimal_size_estimate_requires_aapt2(self):
        with self.assertRaisesRegex(bundle.BundleError, 'requires --aapt2'):
            bundle.estimate_standalone_size(
                'arm64-v8a',
                selected_dir=self.source,
                policy='minimal',
            )

    def test_merged_identity_and_split_requirements_are_verified(self):
        plan = self.select()
        def merged_dump(_tool, _apk, command, *options):
            return manifest() if command == 'xmltree' else resources({'0x7f010001': [''], '0x7f010002': ['xxhdpi-v4']})
        with patch.object(bundle, 'run_aapt2', side_effect=merged_dump):
            bundle.verify_standalone(self.source / 'base.apk', plan, 'aapt2')
        for xml in (manifest(code=124), manifest('config.en'),
                    manifest(app_extra='        A: android:isSplitRequired=true'),
                    manifest(extra='    A: android:requiredSplitTypes="base__abi" (Raw: "base__abi")')):
            with self.subTest(xml=xml), patch.object(bundle, 'run_aapt2', return_value=xml):
                with self.assertRaises(bundle.BundleError):
                    bundle.verify_standalone(self.source / 'base.apk', plan, 'aapt2')
        with patch.object(bundle, 'run_aapt2', side_effect=lambda _tool, _apk, command, *options:
                          manifest() if command == 'xmltree' else resources({'0x7f010001': ['']})):
            with self.assertRaisesRegex(bundle.BundleError, 'lost required resource IDs'):
                bundle.verify_standalone(self.source / 'base.apk', plan, 'aapt2')
        with patch.object(bundle, 'run_aapt2', side_effect=lambda _tool, _apk, command, *options:
                          manifest() if command == 'xmltree' else resources({'0x7f010001': ['en'], '0x7f010002': ['xxhdpi-v4']})):
            with self.assertRaisesRegex(bundle.BundleError, 'lost required resource configurations'):
                bundle.verify_standalone(self.source / 'base.apk', plan, 'aapt2')

    def test_resource_parser_rejects_missing_evidence(self):
        for text in ('', 'Unknown APK', 'Binary APK\nPackage name=com.example id=7f\n    resource 0x7f010001 string/example\n'):
            with self.assertRaises(bundle.BundleError):
                bundle.resource_configs(text)


if __name__ == '__main__':
    unittest.main()
