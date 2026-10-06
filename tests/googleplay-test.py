#!/usr/bin/env python3
"""Unit tests for Google Play FDFE download module (scripts/googleplay.py)."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import scripts.googleplay as gp


class TestWireParser(unittest.TestCase):
    def test_varint(self) -> None:
        self.assertEqual(gp._decode_fields(b"\x08\x01"), [(1, gp.WIRE_VARINT, 1)])
        self.assertEqual(gp._decode_fields(b"\x08\xac\x02"), [(1, gp.WIRE_VARINT, 300)])

    def test_fixed_fields(self) -> None:
        fields = gp._decode_fields(b"\x0d" + struct.pack("<I", 123456))
        self.assertEqual(fields, [(1, gp.WIRE_FIXED32, 123456)])
        fields64 = gp._decode_fields(b"\x09" + struct.pack("<Q", 9876543210))
        self.assertEqual(fields64, [(1, gp.WIRE_FIXED64, 9876543210)])

    def test_bytes_and_nested_message(self) -> None:
        raw = b"hello play"
        fields = gp._decode_fields(b"\x0a" + bytes([len(raw)]) + raw)
        self.assertEqual(gp._text_value(fields, 1), "hello play")

        inner = b"\x12\x0anested_val"
        outer = b"\x0a" + bytes([len(inner)]) + inner
        nested = gp._nested_fields(outer, 1)
        self.assertEqual(gp._text_value(nested, 2), "nested_val")


class TestDeviceProfiles(unittest.TestCase):
    def test_profile_abis(self) -> None:
        arm64 = gp.get_profile_for_arch("arm64-v8a")
        self.assertIn("arm64-v8a", arm64["Platforms"])
        self.assertEqual(arm64["Build.VERSION.SDK_INT"], "33")

        armv7 = gp.get_profile_for_arch("arm-v7a")
        self.assertIn("armeabi-v7a", armv7["Platforms"])
        self.assertNotIn("arm64-v8a", armv7["Platforms"])

        x86_64 = gp.get_profile_for_arch("x86_64")
        self.assertIn("x86_64", x86_64["Platforms"])

        x86 = gp.get_profile_for_arch("x86")
        self.assertIn("x86", x86["Platforms"])
        self.assertNotIn("x86_64", x86["Platforms"])


class TestVersionResolution(unittest.TestCase):
    def test_version_code_direct(self) -> None:
        code, name = gp.resolve_version_code("com.example", "12345", {})
        self.assertEqual(code, 12345)
        self.assertEqual(name, "")

    def test_version_code_combined(self) -> None:
        code, name = gp.resolve_version_code("com.example", "2.1.0:998877", {})
        self.assertEqual(code, 998877)
        self.assertEqual(name, "2.1.0")

    def test_well_known_version_codes(self) -> None:
        code, name = gp.resolve_version_code("com.google.android.youtube", "21.36.47", {})
        self.assertEqual(code, 1561295707)
        self.assertEqual(name, "21.36.47")

        code_ph, name_ph = gp.resolve_version_code("com.google.android.apps.photos", "7.89.0.966319819", {})
        self.assertEqual(code_ph, 52244372)
        self.assertEqual(name_ph, "7.89.0.966319819")

    def test_env_version_codes(self) -> None:
        with patch.dict(os.environ, {"GOOGLE_PLAY_VERSION_CODES": json.dumps({"custom.app": {"1.5.0": 554433}})}):
            code, name = gp.resolve_version_code("custom.app", "1.5.0", {})
            self.assertEqual(code, 554433)
            self.assertEqual(name, "1.5.0")


class TestDigestIntegrity(unittest.TestCase):
    def test_digest_match_and_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_file = Path(td) / "test.apk"
            content = b"sample apk binary payload for testing digests"
            sha256_bytes = hashlib.sha256(content).digest()
            valid_sha256_b64 = base64.urlsafe_b64encode(sha256_bytes).decode("ascii").rstrip("=")

            # Mock urlopen
            mock_resp = MagicMock()
            mock_resp.read.side_effect = [content, b""]
            mock_resp.__enter__.return_value = mock_resp

            with patch("urllib.request.urlopen", return_value=mock_resp):
                # Valid digest succeeds
                gp.download_file("http://example.invalid/apk", out_file, [], expected_sha256=valid_sha256_b64)
                self.assertTrue(out_file.exists())
                self.assertEqual(out_file.read_bytes(), content)

            # Mismatched digest fails and cleans up
            mock_resp2 = MagicMock()
            mock_resp2.read.side_effect = [content, b""]
            mock_resp2.__enter__.return_value = mock_resp2

            bad_sha256_b64 = "invalid_hash_value_that_does_not_match"
            out_file_bad = Path(td) / "bad.apk"
            with patch("urllib.request.urlopen", return_value=mock_resp2):
                with self.assertRaises(gp.PlayIntegrityError):
                    gp.download_file("http://example.invalid/apk", out_file_bad, [], expected_sha256=bad_sha256_b64)
                self.assertFalse(out_file_bad.exists())


class TestCredentialSafety(unittest.TestCase):
    def test_manifest_contains_zero_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_bundle = Path(td) / "output.bundle"

            mock_auth = {
                "authToken": "SECRET_AUTH_TOKEN_DO_NOT_LEAK",
                "gsfId": "SECRET_GSF_ID_3829104",
                "dfeCookie": "SECRET_COOKIE_XYZ",
                "_cached_at": 1000,
            }
            mock_delivery = {
                "downloadUrl": "http://example.invalid/base",
                "downloadSize": 100,
                "sha1": "abcdef",
                "sha256": "base_hash",
                "cookies": ["token=secret_cookie_val"],
                "splits": [
                    {
                        "name": "config.arm64_v8a",
                        "url": "http://example.invalid/split",
                        "size": 50,
                        "sha256": "split_hash",
                    }
                ],
            }

            with patch("scripts.googleplay.authenticate", return_value=mock_auth), \
                 patch("scripts.googleplay.resolve_version_code", return_value=(1561295707, "21.36.47")), \
                 patch("scripts.googleplay.purchase", return_value="dtok"), \
                 patch("scripts.googleplay.get_delivery", return_value=mock_delivery), \
                 patch("scripts.googleplay.download_file") as mock_dl:

                # Create dummy downloaded files when download_file is invoked
                def fake_dl(url, dest, cookies, expected_sha256="", expected_sha1=""):
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(b"PK\x05\x06" + b"\x00" * 18)  # empty valid zip

                mock_dl.side_effect = fake_dl

                manifest = gp.download_package("com.google.android.youtube", "21.36.47", "arm64-v8a", out_bundle)

                manifest_json = json.dumps(manifest)
                self.assertNotIn("SECRET_AUTH_TOKEN", manifest_json)
                self.assertNotIn("SECRET_GSF_ID", manifest_json)
                self.assertNotIn("SECRET_COOKIE", manifest_json)
                self.assertNotIn("secret_cookie_val", manifest_json)

                # Check on disk source.json as well
                source_json_path = Path(f"{out_bundle}.source.json")
                self.assertTrue(source_json_path.exists())
                disk_content = source_json_path.read_text(encoding="utf-8")
                self.assertNotIn("SECRET_AUTH_TOKEN", disk_content)
                self.assertNotIn("SECRET_GSF_ID", disk_content)
                self.assertNotIn("SECRET_COOKIE", disk_content)
                self.assertNotIn("secret_cookie_val", disk_content)


if __name__ == "__main__":
    unittest.main()
