"""Check the iOS environment fields used by the Flutter Sauce runner."""

import importlib.util
import json
import unittest
from html import escape
from pathlib import Path


SCRIPT = (Path(__file__).resolve().parents[1] / "Flutter/apps/tmk_translation_demo"
          / "saucelabs/test_online_listen.py")
SPEC = importlib.util.spec_from_file_location("flutter_sauce_online_listen", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeDriver:
    capabilities = {"deviceName": "iPhone", "timeZone": "America/Los_Angeles"}
    session_id = "session-1"

    def __init__(self, *, simulated_location=None, location_error=None,
                 app_environment=None):
        self.simulated_location = simulated_location
        self.location_error = location_error
        self.app_environment = app_environment or {"status": "permission_denied"}

    def execute_script(self, name):
        if name == "mobile: deviceInfo":
            return {"currentLocale": "en_US", "timeZone": "America/Los_Angeles"}
        if name == "mobile: getSimulatedLocation":
            return self.simulated_location
        raise AssertionError(name)

    def find_elements(self, *_args):
        return []

    @property
    def location(self):
        if self.location_error:
            raise self.location_error
        return {"latitude": 37.389, "longitude": -121.962, "altitude": 5}

    @property
    def page_source(self):
        label = escape("TMK_DEVICE_ENV=" + json.dumps(self.app_environment), quote=True)
        return f'<hierarchy><node label="{label}"/></hierarchy>'


class DeviceEnvironmentTests(unittest.TestCase):
    def test_ios_reads_current_locale_and_direct_location(self):
        environment = MODULE.device_environment(FakeDriver(), "iOS", "us-west-1")
        self.assertEqual(environment["device_locale"], "en_US")
        self.assertEqual(environment["device_language"], "en")
        self.assertEqual(environment["gps_source"], "appium_location")
        self.assertEqual(environment["gps"]["latitude"], 37.389)

    def test_ios_uses_simulated_location_after_wda_location_error(self):
        driver = FakeDriver(
            location_error=RuntimeError("WDA location permission unavailable"),
            simulated_location={"latitude": 37.768, "longitude": -121.959},
        )
        environment = MODULE.device_environment(driver, "iOS", "us-west-1")
        self.assertEqual(environment["gps_source"], "appium_simulated_location")
        self.assertEqual(environment["gps"]["latitude"], 37.768)
        self.assertEqual(environment["capture_errors"]["gps"], "RuntimeError")
        self.assertIn("WDA location", environment["capture_errors"]["gps_detail"])

    def test_unset_simulated_location_is_not_reported_as_gps(self):
        driver = FakeDriver(location_error=RuntimeError("no location"),
                            simulated_location={"latitude": None, "longitude": None})
        environment = MODULE.device_environment(driver, "iOS", "us-west-1")
        self.assertIsNone(environment["gps"])
        self.assertIsNone(environment["gps_source"])

    def test_zero_coordinates_do_not_claim_a_device_location(self):
        self.assertIsNone(MODULE.valid_location({"latitude": 0, "longitude": 0}))

    def test_app_core_location_fills_wda_permission_gap(self):
        driver = FakeDriver(
            location_error=RuntimeError("WDA needs Always permission"),
            app_environment={
                "status": "ok",
                "locale": "en_US",
                "timeZone": "America/Los_Angeles",
                "gps": {"latitude": 37.768, "longitude": -121.959,
                        "horizontal_accuracy_m": 20},
            },
        )
        environment = MODULE.device_environment(driver, "iOS", "us-west-1")
        self.assertEqual(environment["gps_source"], "app_core_location")
        self.assertEqual(environment["gps"]["latitude"], 37.768)
        self.assertEqual(environment["gps_accuracy_m"], 20)
        self.assertEqual(environment["app_location_status"], "ok")

    def test_android_reports_app_precision_and_location_source(self):
        driver = FakeDriver(app_environment={
            "status": "ok", "locale": "en_US", "timeZone": "America/Los_Angeles",
            "location_source": "cached_fused", "location_age_ms": 1200,
            "location_permission": "precise", "precision_status": "precise",
            "providers": ["fused", "network", "gps"],
            "gps": {"latitude": 37.3891, "longitude": -121.9621,
                    "horizontal_accuracy_m": 18},
            "geocode_status": "ok", "address": {"country": "United States"},
        })
        environment = MODULE.device_environment(driver, "Android", "us-west-1")
        self.assertEqual(environment["gps_source"], "app_android_location")
        self.assertEqual(environment["gps_accuracy_m"], 18)
        self.assertEqual(environment["app_location_source"], "cached_fused")
        self.assertEqual(environment["app_location_age_ms"], 1200)
        self.assertEqual(environment["app_precision_status"], "precise")
        self.assertIsNotNone(environment["gps_consistency_distance_km"])


if __name__ == "__main__":
    unittest.main()
