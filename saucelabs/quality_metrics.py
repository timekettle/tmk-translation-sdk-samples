"""Metrics shared by the native and Flutter Sauce listening tests."""

from __future__ import annotations

import json
import os
import re
import ssl
import string
import time
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass


REFERENCE_TEXT = (
    "Good. Do you have any fruits or plants with you?, "
    "Great. How about any meat or dairy products?, "
    "Let me check those snacks. Are they all commercially - packaged?, "
    "Okay. Everything seems to be in order. Do you have any items to declare? "
    "Like high - value electronics or large amounts of cash."
)
METRICS_PREFIX = "TMK_TEST_METRICS="
CHINESE_PUNCTUATION = "！？｡。、（）《》「」『』【】；：，。…—‘’“”"
PUNCTUATION = set(string.punctuation + CHINESE_PUNCTUATION)
LLM_ENDPOINT = "https://new-api.timekettle.net/v1/chat/completions"


def display_metric(value: object) -> str:
    return str(value) if value is not None else "未取得"


def display_percent(value: object) -> str:
    return f"{value}%" if value is not None else "未取得"


@dataclass(frozen=True)
class AsrMetrics:
    wer_percent: float
    cer_percent: float
    accuracy_percent: float
    recognized_text: str


def _normalize(value: str) -> str:
    return " ".join("".join(char for char in value if char not in PUNCTUATION).lower().split())


def _distance(reference: list[str], actual: list[str]) -> int:
    previous = list(range(len(actual) + 1))
    for row, expected in enumerate(reference, 1):
        current = [row]
        for column, observed in enumerate(actual, 1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (expected != observed),
            ))
        previous = current
    return previous[-1]


def compose_final_text(segments: list[str]) -> str:
    """Merge final chunks, including cumulative revisions of an earlier chunk."""
    merged = ""
    for raw in segments:
        part = raw.strip().removesuffix("...").removesuffix("…").strip()
        if not part:
            continue
        if not merged:
            merged = part
        elif part == merged or merged.endswith(part):
            continue
        elif part.startswith(merged) or merged in part:
            merged = part
        else:
            overlap = next((size for size in range(min(len(merged), len(part)), 0, -1)
                            if merged[-size:] == part[:size]), 0)
            merged = merged + part[overlap:] if overlap else merged + " " + part
    return merged


def calculate_asr(reference: str, segments: list[str]) -> AsrMetrics:
    actual = compose_final_text(segments)
    ref = _normalize(reference)
    hyp = _normalize(actual)
    ref_words, hyp_words = ref.split(), hyp.split()
    ref_chars = list(ref.replace(" ", ""))
    hyp_chars = list(hyp.replace(" ", ""))
    wer = _distance(ref_words, hyp_words) / len(ref_words) if ref_words else float(bool(hyp_words))
    cer = _distance(ref_chars, hyp_chars) / len(ref_chars) if ref_chars else float(bool(hyp_chars))
    return AsrMetrics(
        wer_percent=round(wer * 100, 2),
        cer_percent=round(cer * 100, 2),
        accuracy_percent=round(max(0.0, 1.0 - wer) * 100, 2),
        recognized_text=actual,
    )


def parse_app_metrics(page_source: str) -> dict | None:
    root = ET.fromstring(page_source)
    for element in root.iter():
        for value in element.attrib.values():
            position = value.find(METRICS_PREFIX)
            if position < 0:
                continue
            candidate = value[position + len(METRICS_PREFIX):]
            try:
                parsed, _ = json.JSONDecoder().raw_decode(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict) and parsed.get("schema_version") == 1:
                return parsed
    return None


def collect_app_metrics(driver, timeout_seconds: int = 90) -> dict:
    """Wait for all callbacks and an eight-second quiet period after final text."""
    deadline = time.monotonic() + timeout_seconds
    last_text = None
    quiet_since = None
    last_payload = None
    while time.monotonic() < deadline:
        payload = parse_app_metrics(driver.page_source)
        if payload is not None:
            last_payload = payload
            has_required = (
                payload.get("input_started")
                and all(payload.get(key) is not None for key in
                        ("first_asr_ms", "first_mt_ms", "first_tts_packet_ms"))
                and payload.get("asr_final_segments")
                and payload.get("mt_final_segments")
            )
            if has_required:
                text_state = (tuple(payload["asr_final_segments"]), tuple(payload["mt_final_segments"]))
                if text_state != last_text:
                    last_text = text_state
                    quiet_since = time.monotonic()
                elif quiet_since is not None and time.monotonic() - quiet_since >= 8:
                    return payload
        time.sleep(2)
    missing = []
    if last_payload is None:
        missing.append("app metrics element")
    else:
        missing.extend(key for key in ("first_asr_ms", "first_mt_ms", "first_tts_packet_ms")
                       if last_payload.get(key) is None)
        missing.extend(key for key in ("asr_final_segments", "mt_final_segments")
                       if not last_payload.get(key))
    raise TimeoutError("Could not collect complete test metrics: " + ", ".join(missing or ["final text not settled"]))


def translation_match(source_text: str, translated_text: str,
                      source_language: str = "en-US", target_language: str = "zh-CN",
                      reference_translation: str | None = None) -> dict:
    """Use the same source-transcript semantic scoring contract as SDK L4."""
    key = os.environ.get("TMK_L4_LLM_API_KEY", "").strip()
    if not key:
        return {"status": "not_configured", "percent": None,
                "reason": "Set TMK_L4_LLM_API_KEY to score translation quality"}
    if not translated_text.strip():
        return {"status": "scored", "percent": 0}
    reference_line = (f"人工参考译文：{reference_translation}\n"
                      if reference_translation else "")
    prompt = f"""
你是机器翻译质量评测器。请依据“音频原始转写文本”（源语言）和可选的人工参考译文，评估“SDK 翻译输出”是否准确、完整地译成目标语言。允许同义表达，不要求与参考译文字面一致。只输出一个 0% 到 100% 的整数百分比，不要输出解释。

评分规则：
1. 译文忠实、完整地表达原文含义且使用目标语言，输出 100%；允许同义表达、自然语序及标点差异。
2. “周五”和“星期五”这类同义表达应视为 100%。
3. 数字、日期、时间、地点、人名、否定、方向、单位、语言对象错误需要明显扣分。
4. 译文遗漏、添加或误译原文信息应扣分；为空、无关、反义或未使用目标语言，输出 0%。
5. 只输出一个整数百分比，例如 100%。

任务类型：MT_MATCH
源语言：{source_language}
目标语言：{target_language}
音频原始转写文本：{source_text}
{reference_line}
SDK 翻译输出：{translated_text}
""".strip()
    request = urllib.request.Request(
        LLM_ENDPOINT,
        data=json.dumps({"model": os.environ.get("TMK_L4_LLM_MODEL", "").strip() or "gpt-4o",
                         "messages": [{"role": "user", "content": prompt}],
                         "temperature": 0}).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    context = ssl.create_default_context()
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    last_error = "unknown"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30, context=context) as response:
                payload = json.load(response)
            answer = payload["choices"][0]["message"]["content"]
            match = re.fullmatch(r"\s*(100|[1-9]?\d)\s*%?\s*", answer)
            if match is None:
                raise ValueError("LLM score must be one integer percentage")
            return {"status": "scored", "percent": int(match.group(1))}
        except Exception as error:
            last_error = type(error).__name__
            if attempt < 2:
                time.sleep(attempt + 1)
    return {"status": "failed", "percent": None, "reason": last_error}


def calculate_quality(app_metrics: dict, reference_text: str = REFERENCE_TEXT,
                      source_language: str = "en-US", target_language: str = "zh-CN",
                      reference_translation: str | None = None) -> dict:
    asr_segments = app_metrics.get("asr_final_segments") or []
    mt_segments = app_metrics.get("mt_final_segments") or []
    asr = calculate_asr(reference_text, asr_segments)
    error_metric = "CER" if source_language.split("-", 1)[0].lower() in {"zh", "ja", "ko"} else "WER"
    error_percent = asr.cer_percent if error_metric == "CER" else asr.wer_percent
    translated = compose_final_text(mt_segments)
    return {
        "definition": "first callback measured from first test PCM frame pushed to SDK; TTS requires a PCM16LE sample with absolute value > 2",
        "first_asr_ms": app_metrics.get("first_asr_ms"),
        "first_mt_ms": app_metrics.get("first_mt_ms"),
        "first_audio_callback_ms": app_metrics.get("first_audio_callback_ms"),
        "first_tts_packet_ms": app_metrics.get("first_tts_packet_ms"),
        "asr": {"reference_text": reference_text, "recognized_text": asr.recognized_text,
                "wer_percent": asr.wer_percent, "cer_percent": asr.cer_percent,
                "error_metric": error_metric, "error_percent": error_percent,
                "accuracy_percent": round(max(0.0, 100.0 - error_percent), 2),
                "accuracy_definition": f"max(0, 100 - {error_metric}%)"},
        "translation": {"translated_text": translated,
                        "reference_translation": reference_translation,
                        "match": translation_match(reference_text, translated,
                                                   source_language, target_language,
                                                   reference_translation)},
    }
