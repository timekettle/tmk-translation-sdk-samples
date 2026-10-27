"""The Flutter runners must select local devices without Sauce capabilities."""

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


SCRIPT = (Path(__file__).resolve().parents[1] / "Flutter/apps/tmk_translation_demo"
          / "saucelabs/test_online_listen.py")
SPEC = importlib.util.spec_from_file_location("flutter_local_online_listen", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LocalBackendTests(unittest.TestCase):
    def setUp(self):
        MODULE._INSTALLED_LOCAL_APKS.clear()

    def test_local_android_uses_udid_and_local_apk_without_sauce_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "sample.apk"
            apk.write_bytes(b"apk")
            environment = {
                "TEST_BACKEND": "local", "LOCAL_DEVICE_UDID": "phone-1",
                "LOCAL_APP_PATH": str(apk),
                "APPIUM_SERVER_URL": "http://127.0.0.1:4723/",
            }
            with patch.dict(os.environ, environment, clear=True), \
                    patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess(
                        args=[], returncode=0, stdout="Performing Streamed Install\nSuccess\n", stderr=""
                    )) as install, \
                    patch.object(MODULE.webdriver, "Remote", return_value=Mock()) as remote:
                driver = MODULE.create_test_driver(
                    "Android", "us-west-1", "local",
                    {"gps": None, "locale": None, "timezone": None}, "local test"
                )
            self.assertIsNotNone(driver)
            self.assertEqual(remote.call_args.kwargs["command_executor"],
                             "http://127.0.0.1:4723")
            capabilities = remote.call_args.kwargs["options"].capabilities
            self.assertEqual(capabilities["appium:udid"], "phone-1")
            self.assertEqual(capabilities["appium:app"], str(apk.resolve()))
            self.assertTrue(capabilities["appium:noReset"])
            self.assertNotIn("sauce:options", capabilities)
            install.assert_called_once_with(
                ["adb", "-s", "phone-1", "install", "-r", str(apk.resolve())],
                capture_output=True, text=True, timeout=180, check=False,
            )

    def test_signature_conflict_stops_before_creating_session(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "sample.apk"
            apk.write_bytes(b"apk")
            environment = {"LOCAL_DEVICE_UDID": "phone-1", "LOCAL_APP_PATH": str(apk)}
            failed = subprocess.CompletedProcess(
                args=[], returncode=1, stdout="",
                stderr="INSTALL_FAILED_UPDATE_INCOMPATIBLE",
            )
            with patch.dict(os.environ, environment, clear=True), \
                    patch.object(MODULE.subprocess, "run", return_value=failed), \
                    patch.object(MODULE.webdriver, "Remote") as remote:
                with self.assertRaisesRegex(RuntimeError, "different signature"):
                    MODULE.create_test_driver(
                        "Android", "us-west-1", "local",
                        {"gps": None, "locale": None, "timezone": None}, "local test"
                    )
            remote.assert_not_called()

    def test_sauce_still_uses_storage_and_ondemand(self):
        environment = {
            "TEST_BACKEND": "sauce", "SAUCE_APP": "storage:file-id",
            "SAUCE_DEVICE_NAME": "Android", "SAUCE_USERNAME": "user",
            "SAUCE_ACCESS_KEY": "key",
        }
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(MODULE.webdriver, "Remote", return_value=Mock()) as remote:
            MODULE.create_test_driver(
                "Android", "us-west-1", "sauce",
                {"gps": None, "locale": None, "timezone": None}, "sauce test"
            )
        self.assertEqual(remote.call_args.kwargs["command_executor"],
                         "https://ondemand.us-west-1.saucelabs.com/wd/hub")
        self.assertIn("sauce:options", remote.call_args.kwargs["options"].capabilities)


if __name__ == "__main__":
    unittest.main()
