"""Small, explicit 3 × 5 corpus contract for Sauce online listening tests."""

from __future__ import annotations

import json
import math
import re
import time
from dataclasses import dataclass
from pathlib import Path
from statistics import mean
from urllib.parse import urlsplit

from saucelabs.remote_audio_probe import preflight_url, signed_url_expires_at

LANGUAGE_CODE = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+$")
CASE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SHA256 = re.compile(r"^[a-fA-F0-9]{64}$")
MAX_AUDIO_SECONDS = 60
BYTES_PER_SECOND = 16_000 * 2


@dataclass(frozen=True)
class CorpusCase:
    case_id: str
    url: str
    source_transcript: str
    reference_translation: str | None
    sha256: str | None


@dataclass(frozen=True)
class CorpusPair:
    source_language: str
    target_language: str
    cases: tuple[CorpusCase, ...]

    @property
    def pair_id(self) -> str:
        return f"{self.source_language}_to_{self.target_language}"


def load_manifest(path: Path) -> tuple[CorpusPair, ...]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ValueError("语料清单需要 schema_version=1")
    pairs = payload.get("pairs")
    if not isinstance(pairs, list) or len(pairs) != 3:
        raise ValueError("小批量语料必须恰好包含 3 个语种对")
    parsed = []
    seen_pairs = set()
    for pair_number, raw_pair in enumerate(pairs, 1):
        if not isinstance(raw_pair, dict):
            raise ValueError(f"第 {pair_number} 个语种对必须是对象")
        source = raw_pair.get("source_language")
        target = raw_pair.get("target_language")
        if not isinstance(source, str) or not LANGUAGE_CODE.fullmatch(source) or \
                not isinstance(target, str) or not LANGUAGE_CODE.fullmatch(target) or \
                source.lower() == target.lower():
            raise ValueError(f"第 {pair_number} 个语种对代码无效或源目标相同")
        pair_key = (source.lower(), target.lower())
        if pair_key in seen_pairs:
            raise ValueError(f"语种对重复：{source}→{target}")
        seen_pairs.add(pair_key)
        raw_cases = raw_pair.get("cases")
        if not isinstance(raw_cases, list) or len(raw_cases) != 5:
            raise ValueError(f"{source}→{target} 必须恰好包含 5 条音频")
        cases = []
        seen_ids = set()
        for case_number, raw_case in enumerate(raw_cases, 1):
            if not isinstance(raw_case, dict):
                raise ValueError(f"{source}→{target} 第 {case_number} 条必须是对象")
            case_id = raw_case.get("id")
            url = raw_case.get("url")
            source_text = raw_case.get("source_transcript")
            translation = raw_case.get("reference_translation")
            digest = raw_case.get("sha256")
            if not isinstance(case_id, str) or not CASE_ID.fullmatch(case_id) or case_id in seen_ids:
                raise ValueError(f"{source}→{target} 第 {case_number} 条 id 无效或重复")
            seen_ids.add(case_id)
            if not isinstance(url, str):
                raise ValueError(f"{source}→{target}/{case_id} 缺少 HTTPS URL")
            if url.startswith("PASTE_SIGNED_HTTPS_URL_FOR_"):
                raise ValueError(f"{source}→{target}/{case_id} 请粘贴新的临时 HTTPS 签名 URL")
            parts = urlsplit(url)
            if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.fragment:
                raise ValueError(f"{source}→{target}/{case_id} 的 URL 必须是完整 HTTPS 地址")
            if not isinstance(source_text, str) or not source_text.strip():
                raise ValueError(f"{source}→{target}/{case_id} 缺少人工核实的源语音转写")
            if translation is not None and not isinstance(translation, str):
                raise ValueError(f"{source}→{target}/{case_id} 的参考译文必须是字符串")
            if isinstance(translation, str):
                translation = translation.strip() or None
            if digest is not None and (not isinstance(digest, str) or not SHA256.fullmatch(digest)):
                raise ValueError(f"{source}→{target}/{case_id} 的 SHA-256 格式无效")
            expires_at = signed_url_expires_at(url)
            if expires_at is not None and expires_at - time.time() < 30 * 60:
                raise ValueError(f"{source}→{target}/{case_id} 的签名 URL 剩余有效期不足 30 分钟")
            cases.append(CorpusCase(case_id, url, source_text.strip(),
                                    translation,
                                    digest.lower() if digest else None))
        parsed.append(CorpusPair(source, target, tuple(cases)))
    return tuple(parsed)


def preflight_manifest(pairs: tuple[CorpusPair, ...]) -> dict[str, dict]:
    """Fetch each unique URL locally; never return the URL or its query string."""
    checked = {}
    for pair in pairs:
        for case in pair.cases:
            if case.url not in checked:
                result = preflight_url(case.url, expected_bytes=None,
                                       expected_sha256=case.sha256)
                duration = result["bytes"] / BYTES_PER_SECOND
                if duration > MAX_AUDIO_SECONDS:
                    raise ValueError(
                        f"{pair.pair_id}/{case.case_id} 超过小批量上限 {MAX_AUDIO_SECONDS} 秒"
                    )
                checked[case.url] = {**result, "duration_seconds": round(duration, 2),
                                     "host": urlsplit(case.url).hostname}
            elif case.sha256 and checked[case.url]["sha256"] != case.sha256:
                raise ValueError(f"{pair.pair_id}/{case.case_id} 的 SHA-256 与重复 URL 不一致")
    return checked


def _average(values: list[float | int]) -> float | None:
    return round(mean(values), 2) if values else None


def _p95(values: list[float | int]) -> float | int | None:
    return sorted(values)[math.ceil(len(values) * 0.95) - 1] if values else None


def summarize_progress(cases: list[dict], *, planned_count: int) -> dict:
    """Overall execution progress, without mixing quality metrics across languages."""
    valid = sum(case.get("status") == "passed" for case in cases)
    failed = sum(case.get("status") == "failed" for case in cases)
    skipped = sum(case.get("status") == "skipped" for case in cases)
    return {
        "planned": planned_count,
        "valid": valid,
        "failed": failed,
        "skipped": skipped,
        "pending": max(0, planned_count - len(cases)),
        "effective_rate_percent": round(valid / planned_count * 100, 2)
        if planned_count else None,
    }


def summarize_cases(cases: list[dict], *, planned_count: int | None = None) -> dict:
    """Quality metrics for one language pair only."""
    valid = [case for case in cases if case.get("status") == "passed"]
    planned = len(cases) if planned_count is None else planned_count
    metrics = [case["quality_metrics"] for case in valid]
    error_metrics = {
        metric.get("asr", {}).get("error_metric") for metric in metrics
        if metric.get("asr", {}).get("error_metric")
    }
    def values(*path: str) -> list[float | int]:
        found = []
        for metric in metrics:
            item = metric
            for key in path:
                item = item.get(key) if isinstance(item, dict) else None
            if isinstance(item, (int, float)) and not isinstance(item, bool):
                found.append(item)
        return found
    return {
        "planned": planned,
        "valid": len(valid),
        "effective_rate_percent": round(len(valid) / planned * 100, 2) if planned else None,
        "average_first_asr_ms": _average(values("first_asr_ms")),
        "average_first_mt_ms": _average(values("first_mt_ms")),
        "average_first_tts_packet_ms": _average(values("first_tts_packet_ms")),
        "p95_first_asr_ms": _p95(values("first_asr_ms")),
        "p95_first_mt_ms": _p95(values("first_mt_ms")),
        "p95_first_tts_packet_ms": _p95(values("first_tts_packet_ms")),
        "latency_valid_counts": {
            "asr": len(values("first_asr_ms")),
            "mt": len(values("first_mt_ms")),
            "tts": len(values("first_tts_packet_ms")),
        },
        "asr_error_metric": next(iter(error_metrics)) if len(error_metrics) == 1 else (
            "mixed" if error_metrics else None
        ),
        "average_asr_error_percent": _average(values("asr", "error_percent")),
        "average_asr_wer_percent": _average(values("asr", "wer_percent")),
        "average_asr_cer_percent": _average(values("asr", "cer_percent")),
        "average_asr_accuracy_percent": _average(values("asr", "accuracy_percent")),
        "average_translation_match_percent": _average(values("translation", "match", "percent")),
        "cpu_peak_p95_percent": None,
        "memory_peak_p95_mb": None,
    }


def summarize_overall_quality(cases: list[dict]) -> dict:
    """Average completed cases globally, while keeping WER and CER distinct."""
    combined = summarize_cases(cases)
    by_metric = {}
    for metric in ("WER", "CER"):
        matching = [
            case for case in cases
            if case.get("status") == "passed"
            and ((case.get("quality_metrics") or {}).get("asr") or {}).get("error_metric") == metric
        ]
        if matching:
            group = summarize_cases(matching)
            by_metric[metric] = {
                "valid": group["valid"],
                "average_error_percent": group["average_asr_error_percent"],
                "average_accuracy_percent": group["average_asr_accuracy_percent"],
            }
    return {
        "valid": combined["valid"],
        "average_first_asr_ms": combined["average_first_asr_ms"],
        "average_first_mt_ms": combined["average_first_mt_ms"],
        "average_first_tts_packet_ms": combined["average_first_tts_packet_ms"],
        "p95_first_asr_ms": combined["p95_first_asr_ms"],
        "p95_first_mt_ms": combined["p95_first_mt_ms"],
        "p95_first_tts_packet_ms": combined["p95_first_tts_packet_ms"],
        "latency_valid_counts": combined["latency_valid_counts"],
        "asr_error_metric": combined["asr_error_metric"],
        "average_asr_error_percent": combined["average_asr_error_percent"],
        "average_asr_accuracy_percent": combined["average_asr_accuracy_percent"],
        "asr_by_error_metric": by_metric,
        "average_translation_match_percent": combined["average_translation_match_percent"],
        "cpu_peak_p95_percent": None,
        "memory_peak_p95_mb": None,
    }
