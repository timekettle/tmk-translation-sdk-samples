"""Checks for explicit region-test inputs before a Sauce session is started."""

import os
import unittest
from unittest.mock import patch

from test_online_listen import gps_distance_km, requested_region_settings


class RegionSettingsTests(unittest.TestCase):
    def test_complete_target_is_normalized(self):
        with patch.dict(os.environ, {
            "SAUCE_TEST_LATITUDE": "48.8566",
            "SAUCE_TEST_LONGITUDE": "2.3522",
            "SAUCE_TEST_LOCALE": "fr-fr",
            "SAUCE_TEST_TIMEZONE": "Europe/Paris",
        }, clear=True):
            self.assertEqual(requested_region_settings(), {
                "gps": {"latitude": 48.8566, "longitude": 2.3522},
                "locale": "fr_FR",
                "timezone": "Europe/Paris",
            })

    def test_partial_or_invalid_location_is_rejected(self):
        with patch.dict(os.environ, {"SAUCE_TEST_LATITUDE": "48.8566"}, clear=True):
            with self.assertRaisesRegex(ValueError, "together"):
                requested_region_settings()
        with patch.dict(os.environ, {
            "SAUCE_TEST_LATITUDE": "91", "SAUCE_TEST_LONGITUDE": "2",
        }, clear=True):
            with self.assertRaisesRegex(ValueError, "valid coordinates"):
                requested_region_settings()

    def test_target_distance_detects_wrong_country(self):
        paris = {"latitude": 48.8566, "longitude": 2.3522}
        london = {"latitude": 51.5074, "longitude": -0.1278}
        self.assertEqual(gps_distance_km(paris, paris), 0)
        self.assertGreater(gps_distance_km(paris, london), 300)


if __name__ == "__main__":
    unittest.main()
