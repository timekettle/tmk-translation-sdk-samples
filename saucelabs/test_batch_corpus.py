"""Validate the 3 × 5 manifest and L4-style small batch summary locally."""

import importlib.util
import json
import tempfile
import unittest
from html import escape
from pathlib import Path
from unittest.mock import Mock, patch

from saucelabs.batch_corpus import (
    load_manifest, preflight_manifest, summarize_cases, summarize_overall_quality,
    summarize_progress,
)
from saucelabs.quality_metrics import calculate_quality

SCRIPT = (Path(__file__).resolve().parents[1] / "Flutter/apps/tmk_translation_demo"
          / "saucelabs/test_online_listen_batch.py")
SPEC = importlib.util.spec_from_file_location("flutter_sauce_batch", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def example_manifest():
    return {
        "schema_version": 1,
        "pairs": [
            {"source_language": source, "target_language": "zh-CN",
             "cases": [
                 {"id": f"p{pair_index}_{case_index}",
                  "url": f"https://example.com/p{pair_index}_{case_index}.pcm",
                  "source_transcript": "Good morning",
                  "reference_translation": "早上好"}
                 for case_index in range(5)]}
            for pair_index, source in enumerate(("en-US", "fr-FR", "ja-JP"))
        ],
    }


class BatchCorpusTests(unittest.TestCase):
    def load(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return load_manifest(path)

    def test_requires_three_pairs_and_five_cases(self):
        payload = example_manifest()
        self.assertEqual(sum(len(pair.cases) for pair in self.load(payload)), 15)
        payload["pairs"][0]["cases"].pop()
        with self.assertRaisesRegex(ValueError, "恰好包含 5 条"):
            self.load(payload)

    def test_requires_source_transcript_but_reference_translation_is_optional(self):
        payload = example_manifest()
        payload["pairs"][0]["cases"][0]["source_transcript"] = ""
        with self.assertRaisesRegex(ValueError, "源语音转写"):
            self.load(payload)
        payload = example_manifest()
        payload["pairs"][0]["cases"][0].pop("reference_translation")
        payload["pairs"][0]["cases"][1]["reference_translation"] = " "
        pairs = self.load(payload)
        self.assertIsNone(pairs[0].cases[0].reference_translation)
        self.assertIsNone(pairs[0].cases[1].reference_translation)
        self.assertEqual(pairs[0].cases[2].reference_translation, "早上好")
        payload["pairs"][0]["cases"][0]["reference_translation"] = 42
        with self.assertRaisesRegex(ValueError, "参考译文必须是字符串"):
            self.load(payload)

    def test_preflight_uses_actual_bytes_and_hash_per_case(self):
        pairs = self.load(example_manifest())
        with patch("saucelabs.batch_corpus.preflight_url",
                   return_value={"http_status": 200, "bytes": 32000,
                                 "sha256": "a" * 64}) as fetch:
            checked = preflight_manifest(pairs)
        self.assertEqual(len(checked), 15)
        self.assertEqual(fetch.call_count, 15)
        self.assertEqual(next(iter(checked.values()))["duration_seconds"], 1.0)

    def test_summary_uses_only_passed_cases_and_nearest_rank_p95(self):
        cases = [
            {"status": "passed", "quality_metrics": {
                "first_asr_ms": value, "first_mt_ms": value + 1,
                "first_tts_packet_ms": value + 2,
                "asr": {"accuracy_percent": 90},
                "translation": {"match": {"percent": 80}}}}
            for value in (1, 2, 3, 4, 5)
        ]
        result = summarize_cases(cases)
        self.assertEqual(result["p95_first_asr_ms"], 5)
        self.assertNotIn("p95_definition", result)
        self.assertEqual(result["effective_rate_percent"], 100)
        self.assertIsNone(result["cpu_peak_p95_percent"])
        twenty = [
            {"status": "passed", "quality_metrics": {
                "first_asr_ms": value, "asr": {}, "translation": {}}}
            for value in range(1, 21)
        ]
        self.assertEqual(summarize_cases(twenty)["p95_first_asr_ms"], 19)

    def test_overall_progress_does_not_mix_quality_averages_across_languages(self):
        result = summarize_progress([
            {"status": "passed"}, {"status": "skipped"}, {"status": "failed"},
        ], planned_count=15)
        self.assertEqual(result, {
            "planned": 15, "valid": 1, "failed": 1, "skipped": 1,
            "pending": 12, "effective_rate_percent": 6.67,
        })
        self.assertNotIn("average_asr_error_percent", result)

    def test_overall_quality_keeps_mean_and_separates_wer_from_cer(self):
        cases = [
            {"status": "passed", "quality_metrics": {
                "first_asr_ms": asr_ms, "first_mt_ms": asr_ms + 1000,
                "first_tts_packet_ms": asr_ms + 2000,
                "asr": {"error_metric": metric, "error_percent": error,
                        "accuracy_percent": 100 - error},
                "translation": {"match": {"percent": score}},
            }}
            for asr_ms, metric, error, score in (
                (1000, "WER", 4, 80),
                (2000, "CER", 5, 60),
                (3000, "CER", 7, 100),
            )
        ]
        result = summarize_overall_quality(cases)
        self.assertEqual(result["average_first_asr_ms"], 2000)
        self.assertEqual(result["p95_first_asr_ms"], 3000)
        self.assertNotIn("p95_definition", result)
        self.assertEqual(result["average_translation_match_percent"], 80)
        self.assertEqual(result["asr_by_error_metric"]["WER"]["average_error_percent"], 4)
        self.assertEqual(result["asr_by_error_metric"]["CER"]["average_error_percent"], 6)
        self.assertNotIn("average_asr_wer_percent", result)

    def test_markdown_shows_pair_metrics_and_return_home_failure(self):
        quality = {
            "first_asr_ms": 1000, "first_mt_ms": 2000,
            "first_tts_packet_ms": 3000,
            "asr": {"error_metric": "WER", "error_percent": 5,
                    "accuracy_percent": 95, "recognized_text": "hello"},
            "translation": {"translated_text": "你好",
                            "match": {"status": "scored", "percent": 0}},
        }
        passed = {"id": "en_01", "status": "passed", "quality_metrics": quality,
                  "source_transcript": "hello", "return_home_error": "TimeoutException"}
        skipped = {"id": "en_02", "status": "skipped",
                   "failure": {"message": "无法返回首页"}}
        report = {
            "status": "failed", "platform": "Android", "execution_backend": "local",
            "sauce_data_center": None, "started_at": "2026-10-26T00:00:00+00:00",
            "finished_at": "2026-10-26T00:01:00+00:00",
            "pairs": [
                {"source_language": "en-US", "target_language": "zh-CN",
                 "session_id": "local-session", "environment": None,
                 "cases": [passed, skipped], "failure": None},
                {"source_language": "zh-CN", "target_language": "en-US",
                 "session_id": None, "environment": None,
                 "cases": [{"id": "zh_01", "status": "skipped"}], "failure": None},
            ],
        }
        markdown = MODULE.render_markdown(report)
        overview = markdown.split("## en-US → zh-CN", 1)[0]
        self.assertIn("完成：**1 条**", overview)
        self.assertIn("**全批次指标（已完成 1 条）**", overview)
        self.assertNotIn("## 全批次指标", markdown)
        self.assertIn("### 各语种对指标均值", overview)
        self.assertIn("| en-US → zh-CN | 1/5 | 1000 | 2000 | 3000 | WER | 5% | 95% | 0% |", overview)
        self.assertIn("| zh-CN → en-US | 0/5 | 未取得 | 未取得 | 未取得 | 未取得 | 未取得 | 未取得 | 未取得 |", overview)
        self.assertEqual(markdown.count("ASR 首字：平均 1000 ms；P95 1000 ms"), 2)
        self.assertNotIn("如何理解 P95", markdown)
        self.assertIn("翻译语义评分：0%（scored）", markdown)
        self.assertIn("返回首页：失败（TimeoutException：无详情）", markdown)
        self.assertIn("#### en_02 · 跳过", markdown)
        self.assertIn("未执行：无法返回首页", markdown)
        self.assertNotIn("None", markdown)

    def test_return_home_falls_back_when_app_click_does_not_navigate(self):
        driver = Mock()
        with patch.object(MODULE, "_home_visible", side_effect=[False, False, True]), \
                patch.object(MODULE, "_wait_for_home", side_effect=[False, True]), \
                patch.object(MODULE.single, "click_control") as click, \
                patch.object(MODULE, "scroll_to_language_pair") as scroll:
            method = MODULE.return_home(driver, "Android")
        self.assertEqual(method, "android_system_back")
        click.assert_called_once()
        driver.back.assert_called_once()
        scroll.assert_called_once_with(driver, "Android")

    def test_chinese_source_uses_cer_for_accuracy(self):
        payload = {"asr_final_segments": ["你好世界"], "mt_final_segments": ["hello"]}
        with patch("saucelabs.quality_metrics.translation_match",
                   return_value={"status": "scored", "percent": 100}):
            result = calculate_quality(payload, reference_text="你好世间",
                                       source_language="zh-CN", target_language="en-US",
                                       reference_translation="hello")
        self.assertEqual(result["asr"]["error_metric"], "CER")
        self.assertEqual(result["asr"]["accuracy_percent"], 75)

    def test_llm_scoring_uses_source_transcript_without_reference_translation(self):
        payload = {"asr_final_segments": ["Good morning"],
                   "mt_final_segments": ["早上好"]}
        with patch("saucelabs.quality_metrics.translation_match",
                   return_value={"status": "scored", "percent": 100}) as score:
            result = calculate_quality(payload, reference_text="Good morning",
                                       source_language="en-US", target_language="zh-CN")
        self.assertEqual(result["translation"]["match"]["percent"], 100)
        score.assert_called_once_with("Good morning", "早上好", "en-US", "zh-CN", None)

    def test_reads_language_pair_without_exposing_other_semantics(self):
        label = escape('TMK_LANGUAGE_PAIR={"source":"en-US","target":"zh-CN"}', quote=True)
        source = f'<hierarchy><node content-desc="{label}"/></hierarchy>'
        self.assertEqual(MODULE.parse_home_pair(source),
                         {"source": "en-US", "target": "zh-CN"})

    def test_reads_pair_from_visible_language_cards_when_parent_label_is_missing(self):
        source = (
            '<hierarchy><node resource-id="tmk.sauce.home.sourceLanguage" '
            'content-desc="源语言&#10;简体&#10;zh-CN"/>'
            '<node resource-id="tmk.sauce.home.targetLanguage" '
            'content-desc="目标语言&#10;美国&#10;en-US"/></hierarchy>'
        )
        self.assertEqual(MODULE.parse_home_pair(source),
                         {"source": "zh-CN", "target": "en-US"})

    def test_visible_pair_does_not_depend_on_appium_is_displayed(self):
        label = escape('TMK_LANGUAGE_PAIR={"source":"zh-CN","target":"en-US"}', quote=True)
        driver = Mock()
        driver.page_source = f'<hierarchy><node content-desc="{label}"/></hierarchy>'
        with patch.object(MODULE.single, "identifier_elements", return_value=[]) as ids:
            pair = MODULE.scroll_to_language_pair(driver, "Android")
        self.assertEqual(pair, {"source": "zh-CN", "target": "en-US"})
        ids.assert_not_called()

    def test_swapping_language_pair_waits_for_updated_home_state(self):
        driver = Mock()
        desired = '<node content-desc="' + escape(
            'TMK_LANGUAGE_PAIR={"source":"en-US","target":"zh-CN"}', quote=True
        ) + '"/>'
        swap = Mock()
        swap.click.side_effect = lambda: setattr(driver, "page_source", desired)
        with patch.object(MODULE, "scroll_to_language_pair",
                          return_value={"source": "zh-CN", "target": "en-US"}), \
                patch.object(MODULE, "language_control_elements", return_value=[swap]) as controls:
            MODULE.set_language_pair(driver, "Android", "en-US", "zh-CN")
        self.assertEqual(controls.call_args.args[1], "tmk.sauce.home.swap")
        swap.click.assert_called_once()

    def test_android_language_control_uses_raw_semantics_when_visibility_is_false(self):
        driver = Mock()
        source = Mock()
        driver.find_elements.return_value = [source]
        with patch.object(MODULE.single, "identifier_elements", return_value=[]):
            found = MODULE.language_control_elements(
                driver, "tmk.sauce.home.sourceLanguage", "源语言", "Android"
            )
        self.assertEqual(found, [source])
        self.assertIn('//*[@resource-id="tmk.sauce.home.sourceLanguage"',
                      driver.find_elements.call_args.args[1])

    def test_android_language_picker_scrolls_its_list_to_japanese(self):
        driver = Mock()
        scrollable = Mock()
        scrollable.id = "language-sheet"
        driver.find_elements.return_value = [scrollable]
        driver.execute_script.return_value = True
        control = Mock()
        japanese = Mock()
        probes = 0

        def controls(_, identifier, label, platform):
            nonlocal probes
            self.assertEqual(platform, "Android")
            if identifier == "tmk.sauce.home.sourceLanguage":
                return [control]
            self.assertEqual(identifier, "tmk.sauce.language.ja-JP")
            probes += 1
            return [japanese] if probes == 15 else []

        with patch.object(MODULE, "language_control_elements", side_effect=controls):
            MODULE.choose_language(driver, "Android", source=True, code="ja-JP")
        control.click.assert_called_once()
        japanese.click.assert_called_once()
        self.assertEqual(driver.execute_script.call_count, 14)
        self.assertEqual(driver.execute_script.call_args.args[1]["elementId"],
                         "language-sheet")

    def test_android_signed_url_uses_send_keys_without_mobile_type(self):
        driver = Mock()
        field = Mock()
        button = Mock()
        button.is_enabled.return_value = True
        signed_url = "https://example.com/test.pcm?Expires=123&Key=id&Signature=value"
        with patch.object(MODULE.single, "identifier_elements", return_value=[field]), \
                patch.object(MODULE.single, "download_button", return_value=button):
            method = MODULE.single.enter_remote_url(driver, signed_url, "Android")
        self.assertEqual(method, "send_keys")
        field.clear.assert_called_once()
        field.send_keys.assert_called_once_with(signed_url)
        driver.execute_script.assert_not_called()

    def test_region_target_requires_app_location(self):
        environment = {"gps": {"latitude": 37.0, "longitude": -122.0},
                       "gps_source": "appium_location"}
        target = {"gps": {"latitude": 37.0, "longitude": -122.0},
                  "locale": None, "timezone": None}
        with self.assertRaisesRegex(RuntimeError, "App 内核实模拟 GPS"):
            MODULE.verify_region_target(environment, target)

    def test_batch_errors_hide_signed_urls(self):
        pairs = self.load(example_manifest())
        secret_url = pairs[0].cases[0].url
        self.assertEqual(MODULE.redact_manifest_urls(f"fetch failed: {secret_url}", pairs),
                         "fetch failed: [REDACTED_URL]")


if __name__ == "__main__":
    unittest.main()
