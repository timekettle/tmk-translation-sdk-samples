"""Checks for the on-device PCM download report and preflight URL validation."""

import json
import io
import unittest
from html import escape
from urllib.error import HTTPError
from unittest.mock import patch

from saucelabs.remote_audio_probe import (
    EXPECTED_BYTES, EXPECTED_SHA256, URL_PLACEHOLDER,
    configured_url, parse_download, preflight_url, redact_url,
    signed_url_expires_at, wait_and_verify,
)


class FakeDriver:
    def __init__(self, result):
        label = escape("TMK_TEST_DOWNLOAD=" + json.dumps(result), quote=True)
        self.page_source = f'<hierarchy><node content-desc="{label}"/></hierarchy>'


class FakeResponse:
    status = 200

    def __init__(self, url, content):
        self.url = url
        self.content = content

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def geturl(self):
        return self.url

    def read(self, _limit):
        return self.content


class RemoteAudioProbeTests(unittest.TestCase):
    def test_placeholder_rejected_before_session_creation(self):
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaisesRegex(ValueError, "Paste the HTTPS PCM URL"):
                configured_url(URL_PLACEHOLDER, required=True)

    def test_signed_url_near_expiry_is_rejected_before_session(self):
        url = "https://example.com/en_0.pcm?Expires=1300&Signature=secret"
        with patch.dict("os.environ", {}, clear=True), \
             patch("saucelabs.remote_audio_probe.time.time", return_value=1001):
            with self.assertRaisesRegex(ValueError, "不足 5 分钟"):
                configured_url(url)

    def test_oss_v4_expiration_is_read_without_signature(self):
        url = ("https://example.com/en_0.pcm?x-oss-date=20261026T060000Z"
               "&x-oss-expires=3600&x-oss-signature=secret")
        self.assertEqual(signed_url_expires_at(url), 1792998000.0)

    def test_report_is_read_from_app_semantics(self):
        result = {"status": "ok", "http_status": 200,
                  "bytes": EXPECTED_BYTES, "sha256": EXPECTED_SHA256}
        self.assertEqual(parse_download(FakeDriver(result).page_source), result)
        report = {}
        self.assertEqual(wait_and_verify(FakeDriver(result), report), result)
        self.assertEqual(report["download"], result)

    def test_hash_mismatch_keeps_evidence_in_report(self):
        result = {"status": "ok", "http_status": 200,
                  "bytes": EXPECTED_BYTES, "sha256": "wrong"}
        report = {}
        with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
            wait_and_verify(FakeDriver(result), report)
        self.assertEqual(report["download"], result)

    def test_idle_download_fails_fast_and_keeps_status(self):
        report = {}
        with self.assertRaisesRegex(RuntimeError, "状态=idle"):
            wait_and_verify(FakeDriver({"status": "idle"}), report,
                            timeout=10, startup_timeout=0)
        self.assertEqual(report["download"], {"status": "idle"})

    def test_preflight_checks_content_before_sauce_session(self):
        url = "https://example.com/en_0.pcm?Signature=secret"
        with patch("saucelabs.remote_audio_probe.urlopen",
                   return_value=FakeResponse(url, b"abcd")):
            self.assertEqual(preflight_url(
                url, expected_bytes=4,
                expected_sha256="88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589",
            )["bytes"], 4)

    def test_preflight_reports_oss_code_without_signed_url(self):
        url = "https://example.com/en_0.pcm?Signature=secret"
        error = HTTPError(url, 403, "Forbidden", {},
                          io.BytesIO(b"<Error><Code>RequestHasExpired</Code></Error>"))
        with patch("saucelabs.remote_audio_probe.urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "OSS Code=RequestHasExpired") as caught:
                preflight_url(url)
        self.assertNotIn("Signature=secret", str(caught.exception))

    def test_signed_query_is_redacted_from_local_xml(self):
        url = "https://example.com/en_0.pcm?Expires=1&Signature=secret"
        source = f'<node label="{escape(url, quote=True)}"/>'
        self.assertNotIn("Signature=secret", redact_url(source, url))


if __name__ == "__main__":
    unittest.main()
