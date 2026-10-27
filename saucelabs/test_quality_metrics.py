import io
import unittest
from unittest.mock import patch

from saucelabs.quality_metrics import (
    REFERENCE_TEXT,
    calculate_asr,
    compose_final_text,
    parse_app_metrics,
    translation_match,
)


class QualityMetricsTests(unittest.TestCase):
    def test_exact_transcript_scores_zero_error(self):
        metrics = calculate_asr(REFERENCE_TEXT, [REFERENCE_TEXT])
        self.assertEqual(metrics.wer_percent, 0)
        self.assertEqual(metrics.cer_percent, 0)
        self.assertEqual(metrics.accuracy_percent, 100)

    def test_word_and_character_errors_have_distinct_denominators(self):
        metrics = calculate_asr("Good morning", ["Good evening"])
        self.assertEqual(metrics.wer_percent, 50)
        self.assertGreater(metrics.cer_percent, 0)
        self.assertNotEqual(metrics.cer_percent, metrics.wer_percent)
        self.assertEqual(metrics.accuracy_percent, 50)

    def test_merges_final_chunks_and_cumulative_revision(self):
        self.assertEqual(compose_final_text(["Good.", "Good. Do you have", "any fruit?"]),
                         "Good. Do you have any fruit?")

    def test_reads_android_and_ios_semantics_payload(self):
        xml = ('<hierarchy><node content-desc="TMK_TEST_METRICS='
               '{&quot;schema_version&quot;:1,&quot;first_asr_ms&quot;:42} 测试指标采集中"/>'
               '</hierarchy>')
        self.assertEqual(parse_app_metrics(xml)["first_asr_ms"], 42)

    def test_missing_llm_key_is_explicit(self):
        with patch.dict("os.environ", {"TMK_L4_LLM_API_KEY": ""}):
            result = translation_match("hello", "你好")
        self.assertEqual(result["status"], "not_configured")
        self.assertIsNone(result["percent"])

    def test_translation_score_parses_integer_percentage(self):
        response = io.BytesIO(b'{"choices":[{"message":{"content":"87%"}}]}')
        with patch.dict("os.environ", {"TMK_L4_LLM_API_KEY": "test-key"}), \
             patch("urllib.request.urlopen", return_value=response):
            result = translation_match("hello", "你好")
        self.assertEqual(result, {"status": "scored", "percent": 87})


if __name__ == "__main__":
    unittest.main()
