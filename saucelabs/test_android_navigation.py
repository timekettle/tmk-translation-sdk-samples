"""Regression checks for merged Compose accessibility nodes on Android."""

import importlib.util
import unittest
from pathlib import Path


SCRIPT = (Path(__file__).resolve().parents[1] / "Android/saucelabs/test_online_listen.py")
SPEC = importlib.util.spec_from_file_location("native_sauce_online_listen", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

PAGE = """<hierarchy>
  <node content-desc="源语言&#10;简体&#10;zh-CN" clickable="true"
        enabled="true" bounds="[55,1438][447,1691]"/>
  <node content-desc="⇄" clickable="true" enabled="true"
        bounds="[480,1504][601,1625]"/>
  <node content-desc="目标语言&#10;美国&#10;en-US" clickable="true"
        enabled="true" bounds="[634,1438][1025,1691]"/>
  <node content-desc="开始翻译" clickable="true" enabled="true"
        bounds="[55,2065][1025,2219]"/>
</hierarchy>"""


class AndroidNavigationTests(unittest.TestCase):
    def test_language_cards_are_read_from_content_description(self):
        self.assertEqual(MODULE.home_language_pair(PAGE), ("zh-CN", "en-US"))

    def test_clickable_controls_are_read_from_content_description(self):
        self.assertEqual(MODULE.enabled_clickable_center(PAGE, "⇄"), (540, 1564))
        self.assertEqual(MODULE.enabled_clickable_center(PAGE, "开始翻译"), (540, 2142))

    def test_session_counts_are_read_from_content_description(self):
        class Driver:
            page_source = '<hierarchy><node content-desc="测试观察：识别0条，翻译0条"/></hierarchy>'

        self.assertEqual(MODULE.result_counts(Driver()), (0, 0))

    def test_flutter_apk_is_detected_before_native_navigation(self):
        flutter_page = '<hierarchy><node resource-id="tmk.sauce.home.start"/></hierarchy>'
        self.assertTrue(MODULE.is_flutter_sample(flutter_page))
        self.assertFalse(MODULE.is_flutter_sample(PAGE))


if __name__ == "__main__":
    unittest.main()
