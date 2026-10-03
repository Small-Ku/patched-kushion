"""Regression coverage for the cache-v3 trust and materialization boundary."""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import stock_cache as cache


class StockCacheTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "source"
        self.output = Path(self.tmp.name) / "stock"
        self.security = {"securityValidated": True, "source": "direct", "artifactSha256": "A" * 64,
                         "comparisonSha256": "B" * 64, "crossSource": {"status": "not-required"}}
        self.summary = {"securityValidated": True, "comparisonSha256": "B" * 64,
                        "crossSource": self.security["crossSource"]}
        self.meta = {"schemaVersion": 2, "status": "ready", "strategy": "partition", "shared": True,
                     "target": "App", "packageName": "com.example", "version": "1.0",
                     "sourceName": "direct", "signerVerified": True, "verification": self.summary,
                     "coverage": {"missingRequired": []},
                     "availableBuildArches": ["universal", "arm64-v8a", "arm-v7a"]}
        cache.write(self.root / "source.json", self.meta)
        cache.write(self.root / "source.security.json", self.security)
        rows = []
        for bucket, name in [("common", "base.apk"), ("common", "config.en.apk"),
                             ("arm64-v8a", "config.arm64.apk"), ("arm-v7a", "config.armv7.apk")]:
            path = self.root / ("common" if bucket == "common" else f"abi/{bucket}") / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
            rows.append({"member": name, "output": name, "bucket": bucket,
                         "abi": cache.BUILD_TO_ANDROID_ABI.get(bucket),
                         "size": path.stat().st_size, "sha256": cache.sha256(path)})
        cache.write(self.root / "partition.json", {"schemaVersion": 1,
                    "availableBuildArches": self.meta["availableBuildArches"], "splits": rows})
        cache.seal_source(self.root, "source-key")

    def prepare(self, arch="arm64-v8a"):
        return cache.prepare(self.root, self.output, "App", "1.0", arch, "source-key")

    def large(self, arch="arm64-v8a"):
        with patch.dict(cache.POLICY, maxPreparedBytes=1):
            self.assertTrue(self.prepare(arch))
            return cache.validate_normalized(self.output, "App", "1.0", arch)

    def test_small_miss_keeps_prepared_stock_path(self):
        self.assertFalse(self.prepare())
        self.assertFalse((self.output / "stock.json").exists())
        self.assertTrue(cache.cacheable(self.output))

    def test_large_hit_is_offline_and_needs_no_merged_apk(self):
        self.large()
        self.assertFalse((self.output / "stock.apk").exists())
        self.assertFalse((self.output / "source/abi/arm-v7a").exists())
        self.assertFalse(cache.cacheable(self.output))
        self.assertEqual(len(list((self.output / "source").rglob("*.apk"))), 3)

    def test_universal_keeps_all_abis_and_common_configs(self):
        concrete = self.large()
        universal = self.large("universal")
        self.assertNotEqual(concrete, universal)
        self.assertEqual(len(list((self.output / "source").rglob("*.apk"))), 4)

    def test_stale_source_identity_and_axes(self):
        for identity in ("", "old-key"):
            with self.assertRaisesRegex(SystemExit, "identity mismatch"):
                cache.validate_source(self.root, identity)
        with self.assertRaisesRegex(SystemExit, "target/version"):
            cache.prepare(self.root, self.output, "Other", "1.0", "arm64-v8a", "source-key")
        with self.assertRaises(SystemExit):
            cache.prepare(self.root, self.output, "App", "2.0", "arm64-v8a", "source-key")
        with self.assertRaises(SystemExit):
            self.prepare("x86")

    def test_input_identity_is_deterministic_and_policy_bound(self):
        first = self.large()
        self.assertEqual(first, self.large())
        with patch.dict(cache.POLICY, maxPreparedBytes=1):
            with self.assertRaisesRegex(SystemExit, "source policy"):
                cache.validate_normalized(self.output, "App", "1.0", "arm64-v8a", "old-source")
        with self.assertRaisesRegex(SystemExit, "schema/policy"):
            cache.validate_normalized(self.output, "App", "1.0", "arm64-v8a")

    def test_tamper_and_extra_splits_fail_closed(self):
        (self.root / "common/base.apk").write_bytes(b"tampered")
        with self.assertRaisesRegex(SystemExit, "digest/size"):
            self.prepare()
        self.setUp()
        (self.root / "common/extra.apk").write_bytes(b"extra")
        with self.assertRaisesRegex(SystemExit, "unlisted APKs"):
            self.prepare()

    def test_stale_security_and_signer_state(self):
        for field in ("signerVerified", "verification"):
            altered = copy.deepcopy(self.meta)
            altered[field] = False if field == "signerVerified" else {}
            cache.write(self.root / "source.json", altered)
            with self.assertRaises(SystemExit):
                cache.seal_source(self.root, "source-key")
        cache.write(self.root / "source.json", self.meta)
        bad = copy.deepcopy(self.security)
        bad["crossSource"] = {"status": "mismatch"}
        cache.write(self.root / "source.security.json", bad)
        with self.assertRaises(SystemExit):
            cache.seal_source(self.root, "source-key")

    def test_cached_normalized_contract_tampering(self):
        self.large()
        with patch.dict(cache.POLICY, maxPreparedBytes=1):
            for target, version, arch in [("Other", "1.0", "arm64-v8a"),
                                           ("App", "2.0", "arm64-v8a"), ("App", "1.0", "universal")]:
                with self.assertRaisesRegex(SystemExit, "axes mismatch"):
                    cache.validate_normalized(self.output, target, version, arch)
            meta = cache.load(self.output / "stock.json")
            meta["inputSha256"] = "0" * 64
            cache.write(self.output / "stock.json", meta)
            with self.assertRaisesRegex(SystemExit, "input identity"):
                cache.validate_normalized(self.output, "App", "1.0", "arm64-v8a")

    def test_unsafe_partition_paths(self):
        meta = cache.load(self.root / "partition.json")
        meta["splits"][0]["output"] = "../../outside.apk"
        cache.write(self.root / "partition.json", meta)
        with self.assertRaisesRegex(SystemExit, "unsafe split"):
            self.prepare()

    def test_branch_standalone_and_split_layout(self):
        self.meta["strategy"] = "branches"
        self.meta["availableBuildArches"] = ["arm64-v8a"]
        cache.write(self.root / "source.json", self.meta)
        branch = self.root / "branches/arm64-v8a"
        cache.write(branch / "branch.json", {"arch": "arm64-v8a", "available": True,
                    "signerVerified": True, "sourceName": "direct", "verification": self.summary})
        (branch / "stock.apk").write_bytes(b"standalone")
        self.security["artifactSha256"] = cache.sha256(branch / "stock.apk")
        cache.write(branch / "source.security.json", self.security)
        cache.seal_source(self.root, "source-key")
        import shutil
        shutil.copytree(branch, self.root / "branch")
        self.large()
        (self.root / "branch/stock.apk").unlink()
        (self.root / "branches/arm64-v8a/stock.apk").unlink()
        for prefix in (branch, self.root / "branch"):
            (prefix / "splits").mkdir()
            (prefix / "splits/base.apk").write_bytes(b"split")
        cache.seal_source(self.root, "source-key")
        self.large()

    def test_dimension_aware_partition_path_is_accepted_and_bucket_bound(self):
        meta = cache.load(self.root / "partition.json")
        common = next(row for row in meta["splits"] if row["bucket"] == "common")
        old = self.root / "common" / common["output"]
        new = self.root / "common/locale/en" / common["output"]
        new.parent.mkdir(parents=True, exist_ok=True)
        old.replace(new)
        common["partitionPath"] = f"common/locale/en/{common['output']}"
        cache.write(self.root / "partition.json", meta)
        cache.seal_source(self.root, "source-key")
        self.large()

        meta = cache.load(self.root / "partition.json")
        common = next(row for row in meta["splits"] if row["bucket"] == "common")
        common["partitionPath"] = f"abi/arm64-v8a/{common['output']}"
        cache.write(self.root / "partition.json", meta)
        with self.assertRaisesRegex(SystemExit, "path/bucket mismatch"):
            cache.seal_source(self.root, "source-key")
    def test_size_cap_includes_embedded_splits(self):
        self.output.mkdir()
        (self.output / "stock.apk").write_bytes(b"123")
        (self.output / "stock-splits").mkdir()
        (self.output / "stock-splits/base.apk").write_bytes(b"456")
        with patch.dict(cache.POLICY, maxPreparedBytes=6):
            self.assertFalse(cache.cacheable(self.output))


if __name__ == "__main__":
    unittest.main()
