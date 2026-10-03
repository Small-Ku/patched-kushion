#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$root" <<'PY'
import contextlib
import hashlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "fdroid_sources", Path(sys.argv[1]) / "scripts/fdroid_sources.py"
)
fdroid = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = fdroid
spec.loader.exec_module(fdroid)

ENDPOINT = "repos/example/app/releases?per_page=100&page=1"
PAYLOAD = b"complete fixture APK"
ASSET = fdroid.Asset(
    source_name="example", repository="example/app", release_tag="v1",
    release_name="Release 1", published_at="", prerelease=False,
    asset_id=123, asset_name="app.apk",
    asset_url="repos/example/app/releases/assets/123",
    browser_download_url="", github_digest="sha256:" + hashlib.sha256(PAYLOAD).hexdigest(),
    size=len(PAYLOAD), token_env=None,
)


def result(*, error="", body="[]"):
    return subprocess.CompletedProcess(["gh"], 1 if error else 0, body, error)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.sleep = self.enterContext(patch.object(fdroid.time, "sleep"))
        self.jitter = self.enterContext(patch.object(fdroid.random, "uniform", return_value=0.25))
        self.logs = self.enterContext(contextlib.redirect_stderr(io.StringIO()))
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.destination = self.directory / "app.apk"

    def json(self):
        return fdroid.gh_json(ENDPOINT, token_env=None)

    def download(self, outcomes, *, asset=ASSET):
        outcomes = iter(outcomes)

        def run(command, **kwargs):
            self.assertEqual(command, [
                "gh", "api", "-H", "Accept: application/octet-stream", asset.asset_url
            ])
            self.assertEqual(kwargs["timeout"], fdroid.GITHUB_DOWNLOAD_TIMEOUT)
            # Failed attempts never create/overwrite the final artifact.
            self.assertEqual(self.destination.read_bytes(), b"previous")
            self.assertEqual(Path(kwargs["stdout"].name).parent, self.directory)
            self.assertEqual(kwargs["stdout"].tell(), 0)
            body, error = next(outcomes)
            kwargs["stdout"].write(body)
            if isinstance(error, Exception):
                raise error
            return subprocess.CompletedProcess(command, 1 if error else 0, None, error.encode())

        self.destination.write_bytes(b"previous")
        with patch.object(fdroid.subprocess, "run", side_effect=run) as mock:
            fdroid.download_asset(asset, self.destination)
        self.assertEqual(list(self.directory.iterdir()), [self.destination])
        return mock

    def test_transient_json_then_success(self):
        errors = [
            "gh: server unavailable (HTTP 504)",
            "gh: server unavailable (HTTP 500)",
            "gh: server unavailable (HTTP 502)",
            "gh: server unavailable (HTTP 503)",
            "stream error: stream ID 1; CANCEL; received from peer",
            "read tcp: connection reset by peer",
            "write tcp: broken pipe",
            "net/http: TLS handshake timeout",
            "read tcp: i/o timeout",
            "read tcp: connection timed out",
            "unexpected EOF", "EOF", "unexpected end of JSON input",
        ]
        for error in errors:
            with self.subTest(error=error):
                self.sleep.reset_mock()
                with patch.object(fdroid.subprocess, "run", side_effect=[
                    result(error=error), result(body='[{"tag_name":"v1"}]')
                ]) as run:
                    self.assertEqual(self.json(), [{"tag_name": "v1"}])
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args.args[0], ["gh", "api", ENDPOINT])
                self.assertEqual(run.call_args.kwargs["timeout"], fdroid.GITHUB_JSON_TIMEOUT)
                self.sleep.assert_called_once_with(2.25)

    def test_json_exhaustion(self):
        with patch.object(fdroid.subprocess, "run", return_value=result(
            error="gh: unavailable (HTTP 504)"
        )) as run:
            with self.assertRaisesRegex(fdroid.SourceError, "HTTP 504.*after 3 attempts"):
                self.json()
        self.assertEqual(run.call_count, 3)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [2.25, 4.25])
        self.assertIn("attempt 2/3", self.logs.getvalue())
        self.assertIn(ENDPOINT, self.logs.getvalue())

    def test_jitter_bounds(self):
        self.jitter.side_effect = [0, 1]
        with patch.object(fdroid.subprocess, "run", side_effect=[
            result(error="unexpected EOF"), result(error="unexpected EOF"), result()
        ]):
            self.assertEqual(self.json(), [])
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [2, 5])
        self.assertEqual([call.args for call in self.jitter.call_args_list], [(0, 1), (0, 1)])

    def test_rate_limit_backoff_and_exhaustion(self):
        with patch.object(fdroid.subprocess, "run", return_value=result(
            error="gh: too many requests (HTTP 429)"
        )) as run:
            with self.assertRaisesRegex(fdroid.SourceError, "HTTP 429.*after 3 attempts"):
                self.json()
        self.assertEqual(run.call_count, 3)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [60.25, 120.25])

    def test_permanent_json_errors_do_not_retry(self):
        errors = [
            "gh: bad credentials (HTTP 401)",
            "gh: forbidden (HTTP 403)",
            "gh: API rate limit exceeded (HTTP 403)",
            "gh: not found (HTTP 404)",
            "gh: validation failed (HTTP 422)",
            "gh: unexpected EOF (HTTP 403)",
            "gh: unavailable (HTTP 503); forbidden (HTTP 403)",
            "please authenticate with gh auth login",
            "unknown flag: --bad", "certificate signed by unknown authority",
            "lookup api.github.com: no such host", "unclassified error",
        ]
        for error in errors:
            with self.subTest(error=error):
                with patch.object(fdroid.subprocess, "run", return_value=result(error=error)) as run:
                    with self.assertRaises(fdroid.SourceError):
                        self.json()
                run.assert_called_once()
        self.sleep.assert_not_called()

    def test_truncated_json_then_success(self):
        for body in ("", "  ", '[{"id":', '[{"name":"cut', "[{}", '[{"id":1,'):
            with self.subTest(body=body):
                with patch.object(fdroid.subprocess, "run", side_effect=[
                    result(body=body), result()
                ]) as run:
                    self.assertEqual(self.json(), [])
                self.assertEqual(run.call_count, 2)

    def test_truncated_json_exhaustion(self):
        with patch.object(fdroid.subprocess, "run", return_value=result(body="[{")) as run:
            with self.assertRaisesRegex(fdroid.SourceError, "truncated JSON.*after 3 attempts"):
                self.json()
        self.assertEqual(run.call_count, 3)

    def test_invalid_json_and_schema_do_not_retry(self):
        for body in ('{"id":}', "<html>bad gateway</html>", "[broken]", "null"):
            with self.subTest(body=body):
                with patch.object(fdroid.subprocess, "run", return_value=result(body=body)) as run:
                    with self.assertRaises(fdroid.SourceError):
                        fdroid.list_releases("example/app", token_env=None,
                                             release_limit=1, include_prereleases=False)
                run.assert_called_once()
        self.sleep.assert_not_called()

    def test_missing_token_does_not_call_transport(self):
        with patch.dict(fdroid.os.environ, {}, clear=True):
            with patch.object(fdroid.subprocess, "run") as run:
                with self.assertRaisesRegex(fdroid.SourceError, "unset token"):
                    fdroid.gh_json(ENDPOINT, token_env="SOURCE_TOKEN")
                with self.assertRaisesRegex(fdroid.SourceError, "unset token"):
                    fdroid.download_asset(replace(ASSET, token_env="SOURCE_TOKEN"), self.destination)
            run.assert_not_called()
        self.sleep.assert_not_called()
        self.assertFalse(self.destination.exists())

    def test_timeout_then_success(self):
        with patch.object(fdroid.subprocess, "run", side_effect=[
            subprocess.TimeoutExpired(["gh"], 60), result()
        ]) as run:
            self.assertEqual(self.json(), [])
        self.assertEqual(run.call_count, 2)
        self.sleep.assert_called_once_with(2.25)

    def test_partial_download_transport_failure_then_success(self):
        for error in (
            "stream error: stream ID 1; CANCEL; received from peer",
            "unexpected end of JSON input", "gh: unavailable (HTTP 504)",
            subprocess.TimeoutExpired(["gh"], 180),
        ):
            with self.subTest(error=error):
                self.sleep.reset_mock()
                run = self.download([(b"partial", error), (PAYLOAD, "")])
                self.assertEqual(run.call_count, 2)
                self.assertEqual(self.destination.read_bytes(), PAYLOAD)
                self.sleep.assert_called_once_with(2.25)

    def test_successful_but_short_download_then_success(self):
        run = self.download([(b"partial", ""), (b"", ""), (PAYLOAD, "")])
        self.assertEqual(run.call_count, 3)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [2.25, 4.25])

    def test_download_exhaustion_preserves_destination_and_cleans_up(self):
        for error in ("", "unexpected EOF"):
            with self.subTest(error=error):
                with self.assertRaisesRegex(fdroid.SourceError, "after 3 attempts"):
                    self.download([(b"partial", error)] * 3)
                self.assertEqual(self.destination.read_bytes(), b"previous")
                self.assertEqual(list(self.directory.iterdir()), [self.destination])

    def test_failed_download_does_not_leave_new_destination(self):
        def run(command, **kwargs):
            kwargs["stdout"].write(b"partial")
            return subprocess.CompletedProcess(command, 1, None, b"unexpected EOF")

        with patch.object(fdroid.subprocess, "run", side_effect=run) as mock:
            with self.assertRaisesRegex(fdroid.SourceError, "after 3 attempts"):
                fdroid.download_asset(ASSET, self.destination)
        self.assertEqual(mock.call_count, 3)
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_permanent_download_error_preserves_destination(self):
        with self.assertRaisesRegex(fdroid.SourceError, "HTTP 404"):
            self.download([(b"partial", "gh: not found (HTTP 404)")])
        self.assertEqual(self.destination.read_bytes(), b"previous")
        self.assertEqual(list(self.directory.iterdir()), [self.destination])
        self.sleep.assert_not_called()

    def test_size_digest_and_digest_schema_errors_do_not_retry(self):
        for body, asset, message in (
            (PAYLOAD + b"extra", ASSET, "size mismatch"),
            (b"x" * len(PAYLOAD), ASSET, "digest mismatch"),
            (PAYLOAD, replace(ASSET, github_digest="md5:invalid"), "Unsupported GitHub digest"),
        ):
            with self.subTest(message=message):
                with self.assertRaisesRegex(fdroid.SourceError, message):
                    self.download([(body, "")], asset=asset)
                self.assertEqual(self.destination.read_bytes(), b"previous")
                self.assertEqual(list(self.directory.iterdir()), [self.destination])
        self.sleep.assert_not_called()

    def test_optional_size_and_digest(self):
        run = self.download([(PAYLOAD, "")], asset=replace(ASSET, size=None, github_digest=None))
        run.assert_called_once()
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.sleep.assert_not_called()


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
