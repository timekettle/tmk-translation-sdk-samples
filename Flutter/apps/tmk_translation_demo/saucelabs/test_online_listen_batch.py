"""Three language pairs × five HTTPS PCM cases on Flutter Sauce real devices."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from saucelabs.batch_corpus import (  # noqa: E402
    load_manifest, preflight_manifest, summarize_cases, summarize_overall_quality,
    summarize_progress,
)
from saucelabs.quality_metrics import calculate_quality, collect_app_metrics  # noqa: E402
from saucelabs.remote_audio_probe import wait_and_verify  # noqa: E402

import test_online_listen as single  # noqa: E402
from appium.webdriver.common.appiumby import AppiumBy  # noqa: E402
from selenium.common.exceptions import TimeoutException  # noqa: E402
from selenium.webdriver.support.ui import WebDriverWait  # noqa: E402

PAIR_PREFIX = "TMK_LANGUAGE_PAIR="
LANGUAGE_CODE_IN_LABEL = re.compile(
    r"(?<![A-Za-z0-9])([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)(?![A-Za-z0-9])"
)


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def redact_manifest_urls(value: object, pairs: tuple = ()) -> str:
    message = str(value)
    for pair in pairs:
        for case in pair.cases:
            message = single.redact_url(message, case.url)
    return message


def parse_home_pair(page_source: str) -> dict | None:
    root = ET.fromstring(page_source)
    for element in root.iter():
        for value in element.attrib.values():
            position = value.find(PAIR_PREFIX)
            if position < 0:
                continue
            try:
                payload, _ = json.JSONDecoder().raw_decode(value[position + len(PAIR_PREFIX):])
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and payload.get("source") and payload.get("target"):
                return payload
    # Some Android accessibility snapshots omit the parent Semantics label
    # while keeping the two visible language cards and their language codes.
    cards = {}
    for element in root.iter():
        label = "\n".join(
            element.attrib.get(attribute, "")
            for attribute in ("content-desc", "label", "name", "text")
        )
        resource_id = element.attrib.get("resource-id", "")
        for side, identifier, heading, other_heading in (
            ("source", "tmk.sauce.home.sourceLanguage", "源语言", "目标语言"),
            ("target", "tmk.sauce.home.targetLanguage", "目标语言", "源语言"),
        ):
            if resource_id != identifier and heading not in label:
                continue
            part = label.split(heading, 1)[-1] if heading in label else label
            part = part.split(other_heading, 1)[0]
            codes = LANGUAGE_CODE_IN_LABEL.findall(part)
            if codes:
                cards[side] = codes[0]
    if {"source", "target"} <= cards.keys():
        return cards
    return None


def scroll_to_language_pair(driver, platform: str) -> dict:
    deadline = time.monotonic() + 90
    scrolls = 0
    while time.monotonic() < deadline:
        page_source = driver.page_source
        pair = parse_home_pair(page_source)
        if pair and pair.get("source") and pair.get("target"):
            return pair
        if scrolls < 8:
            try:
                if platform == "Android":
                    scrollable = driver.find_element(
                        AppiumBy.ANDROID_UIAUTOMATOR, "new UiSelector().scrollable(true)"
                    )
                    driver.execute_script("mobile: scrollGesture", {
                        "elementId": scrollable.id, "direction": "down", "percent": 0.8,
                    })
                else:
                    driver.execute_script("mobile: scroll", {"direction": "down"})
                scrolls += 1
            except Exception:
                pass
        time.sleep(1)
    page_source = driver.page_source
    if "tmk.sauce.listen.back" in page_source:
        raise RuntimeError("App 仍停留在在线收听页，未返回首页")
    if "tmk.sauce.home.start" not in page_source:
        raise RuntimeError("App 当前页面不是首页，无法设置语种对")
    if "在线语言列表加载失败" in page_source or "SDK 初始化失败" in page_source:
        raise RuntimeError("首页在线语言列表或 SDK 初始化失败；请查看保存的页面结构")
    raise RuntimeError("首页可见，但 Appium 未能读取源/目标语种代码；请查看保存的页面结构")


def language_control_elements(driver, identifier: str, label: str, platform: str) -> list:
    elements = single.identifier_elements(driver, identifier, platform)
    if elements:
        return elements
    if platform == "Android":
        # UiAutomator2 may report a visible Flutter Semantics node as not
        # displayed; use the raw resource ID or its clickable description.
        return driver.find_elements(
            AppiumBy.XPATH,
            f'//*[@resource-id="{identifier}" or '
            f'(@clickable="true" and contains(@content-desc, "{label}"))]',
        )
    return single.visible_text_elements(driver, label, exact=False)


def choose_language(driver, platform: str, *, source: bool, code: str) -> None:
    identifier = "tmk.sauce.home.sourceLanguage" if source else "tmk.sauce.home.targetLanguage"
    controls = language_control_elements(
        driver, identifier, "源语言" if source else "目标语言", platform
    )
    if not controls:
        raise RuntimeError(f"未找到语言选择控件：{identifier}")
    controls[0].click()
    choice_id = f"tmk.sauce.language.{code}"
    reached_end = False
    for attempt in range(40):
        choices = language_control_elements(driver, choice_id, code, platform)
        if choices:
            choices[0].click()
            return
        if attempt == 39 or reached_end:
            break
        if platform == "Android":
            scrollables = driver.find_elements(
                AppiumBy.ANDROID_UIAUTOMATOR, "new UiSelector().scrollable(true)"
            )
            if not scrollables:
                raise RuntimeError("语言选择弹窗没有可滚动列表")
            reached_end = driver.execute_script("mobile: scrollGesture", {
                "elementId": scrollables[-1].id,
                "direction": "down", "percent": 0.85,
            }) is False
        else:
            driver.execute_script("mobile: scroll", {"direction": "down"})
    reason = "列表末尾" if reached_end else "40 次滚动后"
    raise RuntimeError(f"在 SDK 在线语言选择列表{reason}仍未找到 {code}")


def set_language_pair(driver, platform: str, source: str, target: str) -> None:
    current = scroll_to_language_pair(driver, platform)
    if (current["source"], current["target"]) == (source, target):
        return
    if (current["source"], current["target"]) == (target, source):
        swap = language_control_elements(driver, "tmk.sauce.home.swap", "⇄", platform)
        if not swap:
            raise RuntimeError("首页未找到交换语种按钮")
        swap[0].click()
    else:
        # HomeScreen refuses to make source and target identical. Free the
        # current code first when the desired pair overlaps the current pair.
        order = ((False, target), (True, source)) if source == current["target"] \
            else ((True, source), (False, target))
        for is_source, code in order:
            latest = scroll_to_language_pair(driver, platform)
            if latest["source" if is_source else "target"] != code:
                choose_language(driver, platform, source=is_source, code=code)
    desired = {"source": source, "target": target}
    WebDriverWait(driver, 15).until(
        lambda current_driver: parse_home_pair(current_driver.page_source) == desired
    )


def create_driver(platform: str, region: str, backend: str,
                  pair_id: str, region_target: dict):
    return single.create_test_driver(
        platform, region, backend, region_target, f"Flutter listen batch / {pair_id}"
    )


def verify_region_target(environment: dict, region_target: dict) -> None:
    if not any(region_target.values()):
        return
    if region_target["gps"]:
        if environment.get("gps_source") not in {"app_android_location", "app_core_location"}:
            raise RuntimeError("无法从 App 内核实模拟 GPS")
        distance = round(single.gps_distance_km(region_target["gps"], environment["gps"]), 2)
        environment["gps_target_distance_km"] = distance
        if distance > 50:
            raise RuntimeError(f"App GPS 距目标位置 {distance} km，超过 50 km")
    if region_target["locale"]:
        actual = str(environment.get("app_device_locale") or "").replace("-", "_")
        if actual.lower() != region_target["locale"].lower():
            raise RuntimeError(f"App 区域语言为 {actual or '未取得'}，目标为 {region_target['locale']}")
    if region_target["timezone"] and \
            environment.get("app_device_timezone") != region_target["timezone"]:
        raise RuntimeError(
            f"App 时区为 {environment.get('app_device_timezone') or '未取得'}，"
            f"目标为 {region_target['timezone']}"
        )


def _home_visible(driver, platform: str) -> bool:
    return bool(single.identifier_elements(driver, "tmk.sauce.home.start", platform))


def _wait_for_home(driver, platform: str, timeout: int) -> bool:
    try:
        WebDriverWait(driver, timeout, poll_frequency=1).until(
            lambda current: _home_visible(current, platform)
        )
        return True
    except TimeoutException:
        return False


def return_home(driver, platform: str) -> str:
    method = "already_home"
    if not _home_visible(driver, platform):
        method = "app_back"
        try:
            single.click_control(driver, "tmk.sauce.listen.back", "Back", platform, timeout=10)
        except Exception:
            # A successful click is not proof that the Flutter route changed.
            # Check the page before trying a platform fallback either way.
            pass
        if not _wait_for_home(driver, platform, 15):
            if platform != "Android":
                raise RuntimeError("点击返回后 App 仍未显示首页")
            for _ in range(2):
                if _home_visible(driver, platform):
                    break
                driver.back()
                method = "android_system_back"
                if _wait_for_home(driver, platform, 10):
                    break
            if not _home_visible(driver, platform):
                raise RuntimeError("App 返回按钮和 Android 返回键均未返回首页")
    scroll_to_language_pair(driver, platform)
    return method


def run_case(driver, platform: str, pair, case, preflight: dict,
             case_directory: Path) -> dict:
    result = {
        "id": case.case_id,
        "status": "failed",
        "source_language": pair.source_language,
        "target_language": pair.target_language,
        "source_transcript": case.source_transcript,
        "reference_translation": case.reference_translation,
        "audio": preflight,
        "started_at": now(),
        "finished_at": None,
        "steps": [],
        "download": None,
        "result_counts": None,
        "quality_metrics": None,
        "failure": None,
        "diagnostics": {},
    }
    step = "进入在线收听"
    entered = False

    def begin(name: str) -> None:
        nonlocal step
        step = name
        result["steps"].append({"name": name, "at": now()})
        print(f"TEST_CASE={pair.pair_id}/{case.case_id} STEP={name}", flush=True)

    try:
        begin("进入在线收听")
        single.click_control(driver, "tmk.sauce.home.start", "开始翻译", platform)
        entered = True
        WebDriverWait(driver, 30).until(
            lambda current: single.visible_text_elements(current, "在线收听")
        )
        begin("选择测试音频")
        single.click_control(driver, "tmk.sauce.listen.testAudio", "测试音频", platform)
        begin("输入 HTTPS URL")
        result["download_input_method"] = single.enter_remote_url(driver, case.url, platform)
        begin("App 下载 PCM")
        button = single.download_button(driver, platform)
        if not button or not button.is_enabled():
            raise RuntimeError("App 下载按钮禁用")
        button.click()
        result["download"] = wait_and_verify(
            driver, result, expected_bytes=preflight["bytes"],
            expected_sha256=preflight["sha256"],
        )
        begin("开始收听并推送音频")
        single.click_control(driver, "tmk.sauce.listen.start", "开始收听", platform, timeout=120)
        WebDriverWait(driver, math.ceil(preflight["duration_seconds"]) + 35).until(
            lambda current: single.control_elements(
                current, "tmk.sauce.listen.audioComplete", "测试音频已推送完毕", platform
            )
        )
        begin("收集识别、翻译和首包")
        counts = WebDriverWait(driver, 90).until(
            lambda current: single.received_results(current, platform)
        )
        result["result_counts"] = {"asr": counts[0], "translation": counts[1]}
        metrics = collect_app_metrics(driver)
        result["quality_metrics"] = calculate_quality(
            metrics, reference_text=case.source_transcript,
            source_language=pair.source_language,
            target_language=pair.target_language,
            reference_translation=case.reference_translation,
        )
        if result["quality_metrics"]["translation"]["match"]["status"] != "scored":
            raise RuntimeError("翻译评分未完成：" +
                               result["quality_metrics"]["translation"]["match"].get("reason", "unknown"))
        result["status"] = "passed"
        print("TEST_CASE_RESULT=" + json.dumps({
            "pair": pair.pair_id, "id": case.case_id, "status": "passed",
            "quality": result["quality_metrics"],
        }, ensure_ascii=False), flush=True)
    except Exception as error:
        result["failure"] = {
            "step": step, "type": type(error).__name__,
            "message": single.redact_url(str(error), case.url)[:1000],
        }
        result["diagnostics"] = single.capture_failure(driver, case_directory, case.url)
        print("TEST_CASE_RESULT=" + json.dumps({
            "pair": pair.pair_id, "id": case.case_id, "status": "failed",
            "failure": result["failure"],
        }, ensure_ascii=False), flush=True)
    finally:
        result["finished_at"] = now()
        if entered:
            try:
                result["return_home_method"] = return_home(driver, platform)
            except Exception as error:
                result["return_home_error"] = type(error).__name__
                result["return_home_detail"] = single.redact_url(str(error), case.url)[:500]
                diagnostics = single.capture_failure(
                    driver, case_directory / "return_home", case.url
                )
                result["diagnostics"].update({
                    f"return_home_{name}": path for name, path in diagnostics.items()
                })
    return result


def _display(value: object, unit: str = "") -> str:
    return f"{value}{unit}" if value is not None else "未取得"


def render_markdown(report: dict) -> str:
    """Readable per-pair quality report; the JSON keeps complete raw detail."""
    cases = [case for pair in report["pairs"] for case in pair["cases"]]
    overall = summarize_progress(cases, planned_count=15)
    overall_quality = summarize_overall_quality(cases)
    pair_interruptions = sum(bool(pair.get("failure")) for pair in report["pairs"])
    return_home_failures = sum(bool(case.get("return_home_error")) for case in cases)
    result_label = {"passed": "全部完成", "failed": "未全部完成",
                    "validated": "清单预检通过"}.get(report["status"], report["status"])
    lines = [
        "# Flutter 在线收听批量测试报告", "",
        f"- 结果：**{result_label}**",
        f"- 平台与执行环境：`{report['platform']}` / `"
        f"{report.get('execution_backend', 'sauce')}`",
        f"- 数据中心：`{report.get('sauce_data_center') or '本地运行，不适用'}`",
        f"- 时间（UTC）：`{report['started_at']}` → "
        f"`{report.get('finished_at') or '进行中'}`",
        "", "## 执行总览", "",
        f"- 计划：{overall['planned']} 条（3 个语种对，每对 5 条）。",
        f"- 完成：**{overall['valid']} 条**；单条测试失败：{overall['failed']} 条；"
        f"跳过：{overall['skipped']} 条；待执行：{overall['pending']} 条。",
        f"- 自动化导航：返回首页失败 {return_home_failures} 条；"
        f"语种对中断 {pair_interruptions} 组。",
        f"- 链路完成率：**{_display(overall['effective_rate_percent'], '%')}**"
        "（完整下载、识别、翻译并取得评分的条数 / 计划条数；不设质量分数门槛）。",
        "- 全批次与各语种对均保留均值；全批次均值按完成的条目计算。",
        "", f"**全批次指标（已完成 {overall_quality['valid']} 条）**", "",
    ]
    if overall_quality["valid"]:
        lines.extend([
            f"- ASR 首字：平均 {_display(overall_quality['average_first_asr_ms'], ' ms')}；"
            f"P95 {_display(overall_quality['p95_first_asr_ms'], ' ms')}。",
            f"- MT 首字：平均 {_display(overall_quality['average_first_mt_ms'], ' ms')}；"
            f"P95 {_display(overall_quality['p95_first_mt_ms'], ' ms')}。",
            f"- TTS 首个有声包：平均 "
            f"{_display(overall_quality['average_first_tts_packet_ms'], ' ms')}；"
            f"P95 {_display(overall_quality['p95_first_tts_packet_ms'], ' ms')}。",
            f"- ASR 准确率：平均 "
            f"{_display(overall_quality['average_asr_accuracy_percent'], '%')}"
            "（各条按其适用的 WER 或 CER 计算，跨语种仅供观察）。",
            f"- 翻译语义评分：平均 "
            f"{_display(overall_quality['average_translation_match_percent'], '%')}。",
        ])
        if overall_quality["asr_error_metric"] == "mixed":
            lines.append(
                f"- ASR 混合错误率：平均 "
                f"{_display(overall_quality['average_asr_error_percent'], '%')}"
                "；包含不同口径，不宜直接比较。"
            )
        for metric, group in overall_quality["asr_by_error_metric"].items():
            lines.append(
                f"- ASR {metric} 子组：{group['valid']} 条；平均错误率 "
                f"{_display(group['average_error_percent'], '%')}；平均准确率 "
                f"{_display(group['average_accuracy_percent'], '%')}。"
            )
    else:
        lines.append("- 尚无完成的条目；均值与 P95 未计算。")
    lines.extend([
        "", "### 各语种对指标均值", "",
        "| 语种对 | 完成/计划 | ASR 首字均值 (ms) | MT 首字均值 (ms) | "
        "TTS 首个有声包均值 (ms) | ASR 错误率口径 | ASR 错误率均值 | "
        "ASR 准确率均值 | 翻译语义评分均值 |",
        "| :--- | ---: | ---: | ---: | ---: | :--- | ---: | ---: | ---: |",
    ])
    for pair in report["pairs"]:
        summary = summarize_cases(pair["cases"], planned_count=5)
        lines.append(
            f"| {pair['source_language']} → {pair['target_language']} | "
            f"{summary['valid']}/{summary['planned']} | "
            f"{_display(summary['average_first_asr_ms'])} | "
            f"{_display(summary['average_first_mt_ms'])} | "
            f"{_display(summary['average_first_tts_packet_ms'])} | "
            f"{summary['asr_error_metric'] or '未取得'} | "
            f"{_display(summary['average_asr_error_percent'], '%')} | "
            f"{_display(summary['average_asr_accuracy_percent'], '%')} | "
            f"{_display(summary['average_translation_match_percent'], '%')} |"
        )
    for pair in report["pairs"]:
        pair_cases = pair["cases"]
        summary = summarize_cases(pair_cases, planned_count=5)
        environment = pair.get("environment") or {}
        valid_count = summary["valid"]
        skipped_count = sum(item.get("status") == "skipped" for item in pair_cases)
        failed_count = sum(item.get("status") == "failed" for item in pair_cases)
        lines.extend([
            "", f"## {pair['source_language']} → {pair['target_language']}", "",
            f"- 进度：完成 **{valid_count}/5**；失败 {failed_count}；"
            f"跳过 {skipped_count}；链路完成率 {_display(summary['effective_rate_percent'], '%')}。",
            f"- Appium 会话：`{pair.get('session_id') or '未创建'}`；"
            f"设备：`{environment.get('device_name') or '未取得'}`。",
        ])
        if environment:
            lines.extend([
                f"- 语言/时区：设备 `{environment.get('device_locale') or '未取得'}` / "
                f"`{environment.get('device_timezone') or '未取得'}`；App "
                f"`{environment.get('app_device_locale') or '未取得'}` / "
                f"`{environment.get('app_device_timezone') or '未取得'}`。",
                f"- 定位：{environment.get('address_summary') or '未取得'}；"
                f"来源 `{environment.get('gps_source') or '未取得'}`；"
                f"状态 `{environment.get('app_location_status') or '未取得'}`。",
            ])
        if failure := pair.get("failure"):
            lines.append(f"- 语种对中断：{failure.get('message') or failure.get('type')}")
        lines.extend(["", "### 本语种对指标", ""])
        if valid_count:
            metric = summary.get("asr_error_metric") or "错误率"
            latency_counts = summary.get("latency_valid_counts") or {}
            lines.extend([
                f"- ASR 首字：平均 {_display(summary.get('average_first_asr_ms'), ' ms')}；"
                f"P95 {_display(summary.get('p95_first_asr_ms'), ' ms')}"
                f"（有效 {latency_counts.get('asr', 0)} 条）。",
                f"- MT 首字：平均 {_display(summary.get('average_first_mt_ms'), ' ms')}；"
                f"P95 {_display(summary.get('p95_first_mt_ms'), ' ms')}"
                f"（有效 {latency_counts.get('mt', 0)} 条）。",
                f"- TTS 首个有声包：平均 {_display(summary.get('average_first_tts_packet_ms'), ' ms')}；"
                f"P95 {_display(summary.get('p95_first_tts_packet_ms'), ' ms')}"
                f"（有效 {latency_counts.get('tts', 0)} 条）。",
                f"- ASR：平均 {metric} {_display(summary.get('average_asr_error_percent'), '%')}；"
                f"平均准确率 {_display(summary.get('average_asr_accuracy_percent'), '%')}。",
                f"- 翻译语义评分：平均 {_display(summary.get('average_translation_match_percent'), '%')}。",
            ])
        else:
            lines.append("- 尚无完成的条目；均值与 P95 未计算。")
        lines.extend(["- CPU 与内存峰值：当前未采集。", "", "### 逐条结果", ""])
        for case in pair_cases:
            status = {"passed": "完成", "failed": "失败", "skipped": "跳过"}.get(
                case.get("status"), case.get("status", "未知")
            )
            lines.extend([f"#### {case['id']} · {status}", ""])
            if case.get("status") == "skipped":
                failure = case.get("failure") or pair.get("failure") or {}
                lines.extend([f"- 未执行：{failure.get('message') or '前序步骤未完成'}。", ""])
                continue
            audio = case.get("audio") or {}
            download = case.get("download") or {}
            quality = case.get("quality_metrics") or {}
            asr = quality.get("asr") or {}
            translation = quality.get("translation") or {}
            match = translation.get("match") or {}
            if audio:
                lines.append(
                    f"- 音频预检：HTTP {_display(audio.get('http_status'))}；"
                    f"{_display(audio.get('bytes'), ' 字节')}；"
                    f"约 {_display(audio.get('duration_seconds'), ' 秒')}。"
                )
            if download:
                matches = (download.get("status") == "ok"
                           and download.get("bytes") == audio.get("bytes")
                           and download.get("sha256") == audio.get("sha256"))
                lines.append(
                    f"- App 下载：{download.get('status') or '未取得'}；"
                    f"HTTP {_display(download.get('http_status'))}；"
                    f"耗时 {_display(download.get('duration_ms'), ' ms')}；"
                    f"字节数和 SHA-256 {'与预检一致' if matches else '未通过校验'}。"
                )
            if quality:
                lines.extend([
                    f"- 首回调：ASR {_display(quality.get('first_asr_ms'), ' ms')}；"
                    f"MT {_display(quality.get('first_mt_ms'), ' ms')}；"
                    f"TTS 有声包 {_display(quality.get('first_tts_packet_ms'), ' ms')}。",
                    f"- 识别：{asr.get('error_metric') or '错误率'} "
                    f"{_display(asr.get('error_percent'), '%')}；"
                    f"准确率 {_display(asr.get('accuracy_percent'), '%')}。",
                    f"- 翻译语义评分：{_display(match.get('percent'), '%')}"
                    f"（{match.get('status') or '未取得'}）。",
                    f"- 识别参考文本：{case.get('source_transcript') or '未提供'}",
                    f"- SDK 识别：{asr.get('recognized_text') or '未取得'}",
                    f"- SDK 译文：{translation.get('translated_text') or '未取得'}",
                ])
                if case.get("reference_translation"):
                    lines.append(f"- 参考译文：{case['reference_translation']}")
            if failure := case.get("failure"):
                lines.append(
                    f"- 失败步骤：{failure.get('step') or '未记录'}；"
                    f"{failure.get('type') or '错误'}：{failure.get('message') or '无详情'}。"
                )
            if error := case.get("return_home_error"):
                detail = case.get("return_home_detail") or "无详情"
                lines.append(f"- 返回首页：失败（{error}：{detail}）；后续条目可能跳过。")
            elif case.get("return_home_method") == "android_system_back":
                lines.append("- 返回首页：App 按钮未完成切换，已用 Android 返回键恢复。")
            for name, path in (case.get("diagnostics") or {}).items():
                if name.endswith("_error"):
                    lines.append(f"- 诊断文件 {name}：{path}")
                else:
                    lines.append(f"- 诊断文件 {name}：[{Path(path).name}]({path})")
            lines.append("")
    if fatal := report.get("fatal_error"):
        lines.extend(["## 初始化失败", "",
                      f"- {fatal.get('type') or '错误'}：{fatal.get('message') or '无详情'}。", ""])
    return "\n".join(lines).rstrip() + "\n"


def write_report(report: dict, directory: Path, *, announce: bool = False) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    json_path = directory / "batch_report.json"
    temporary = directory / "batch_report.json.tmp"
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(json_path)
    markdown_path = directory / "batch_report.md"
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    if announce:
        print("TEST_REPORT=" + json.dumps({"json": str(json_path), "markdown": str(markdown_path)},
                                          ensure_ascii=False), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Flutter Sauce 3 × 5 online listening test")
    parser.add_argument("--manifest", required=True, type=Path,
                        help="Local JSON manifest containing 3 language pairs and 5 HTTPS PCM cases each")
    parser.add_argument("--validate-only", action="store_true",
                        help="Validate all 15 cases and URLs locally without using Sauce minutes")
    args = parser.parse_args()
    platform = single.test_platform()
    backend = single.test_backend()
    region = os.environ.get("SAUCE_REGION", "us-west-1").strip()
    directory = Path(__file__).resolve().parent / "artifacts" / f"batch-{uuid.uuid4().hex[:12]}"
    report = {"schema_version": 2, "status": "failed", "platform": platform,
              "execution_backend": backend,
              "sauce_data_center": region if backend == "sauce" else None,
              "started_at": now(), "finished_at": None,
              "manifest": str(args.manifest.resolve()), "pairs": [],
              "summary": summarize_progress([], planned_count=15),
              "overall_metrics": summarize_overall_quality([]),
              "fatal_error": None}
    pairs = ()
    try:
        pairs = load_manifest(args.manifest)
        print("TEST_STEP=本机预检 15 条 HTTPS PCM", flush=True)
        preflight = preflight_manifest(pairs)
        print("TEST_PREFLIGHT=" + json.dumps({
            "cases": sum(len(pair.cases) for pair in pairs),
            "bytes": sum(preflight[case.url]["bytes"] for pair in pairs for case in pair.cases),
        }), flush=True)
        if args.validate_only:
            report["status"] = "validated"
            return 0
        if not os.environ.get("TMK_L4_LLM_API_KEY", "").strip():
            raise ValueError("完整翻译评分需要先设置 TMK_L4_LLM_API_KEY")
        single.validate_session_setup(platform, region, backend)
        region_target = single.requested_region_settings()
        for pair in pairs:
            pair_report = {"source_language": pair.source_language,
                           "target_language": pair.target_language,
                           "session_id": None, "environment": None,
                           "cases": [], "summary": summarize_cases([], planned_count=5),
                           "failure": None}
            report["pairs"].append(pair_report)
            driver = None
            try:
                print(f"TEST_PAIR={pair.pair_id} STEP=创建 Appium 会话", flush=True)
                driver = create_driver(platform, region, backend, pair.pair_id, region_target)
                pair_report["session_id"] = driver.session_id
                if platform == "Android" and "tmk.sauce.home.start" not in driver.page_source \
                        and "开始在线翻译" in driver.page_source:
                    raise RuntimeError("安装包指向原生 Android Sample；请使用 Flutter APK")
                pair_report["environment"] = single.device_environment(driver, platform, region, backend)
                pair_report["environment"]["region_target"] = region_target
                verify_region_target(pair_report["environment"], region_target)
                print("TEST_ENVIRONMENT=" + json.dumps(pair_report["environment"],
                                                        ensure_ascii=False), flush=True)
                if single.identifier_elements(driver, "tmk.sauce.listen.back", platform):
                    print(f"TEST_PAIR={pair.pair_id} STEP=恢复首页", flush=True)
                    return_home(driver, platform)
                set_language_pair(driver, platform, pair.source_language, pair.target_language)
                for case in pair.cases:
                    case_report = run_case(
                        driver, platform, pair, case, preflight[case.url],
                        directory / pair.pair_id / case.case_id,
                    )
                    pair_report["cases"].append(case_report)
                    pair_report["summary"] = summarize_cases(pair_report["cases"], planned_count=5)
                    report["summary"] = summarize_progress(
                        [item for group in report["pairs"] for item in group["cases"]],
                        planned_count=15,
                    )
                    report["overall_metrics"] = summarize_overall_quality(
                        [item for group in report["pairs"] for item in group["cases"]]
                    )
                    write_report(report, directory)
                    if case_report.get("return_home_error"):
                        raise RuntimeError("无法返回首页，停止当前语种对以避免误测后续语料")
            except Exception as error:
                pair_report["failure"] = {"type": type(error).__name__,
                                          "message": redact_manifest_urls(error, pairs)[:1000]}
                print(f"TEST_PAIR={pair.pair_id} FAILED={type(error).__name__}: "
                      f"{redact_manifest_urls(error, pairs)}", flush=True)
                if driver is not None and not pair_report["cases"]:
                    pair_report["diagnostics"] = single.capture_failure(
                        driver, directory / pair.pair_id / "setup"
                    )
            finally:
                if driver is not None:
                    if backend == "sauce":
                        try:
                            passed = len(pair_report["cases"]) == 5 and all(
                                case["status"] == "passed" for case in pair_report["cases"]
                            )
                            driver.execute_script(f"sauce:job-result={'passed' if passed else 'failed'}")
                        except Exception:
                            pass
                    try:
                        driver.quit()
                    except Exception:
                        pass
            seen = {case["id"] for case in pair_report["cases"]}
            for case in pair.cases:
                if case.case_id not in seen:
                    pair_report["cases"].append({
                        "id": case.case_id, "status": "skipped", "quality_metrics": None,
                        "failure": pair_report["failure"],
                    })
            pair_report["summary"] = summarize_cases(pair_report["cases"], planned_count=5)
            report["summary"] = summarize_progress(
                [item for group in report["pairs"] for item in group["cases"]],
                planned_count=15,
            )
            report["overall_metrics"] = summarize_overall_quality(
                [item for group in report["pairs"] for item in group["cases"]]
            )
            write_report(report, directory)
        report["status"] = "passed" if report["summary"]["valid"] == 15 else "failed"
        return 0 if report["status"] == "passed" else 1
    except Exception as error:
        safe_message = redact_manifest_urls(error, pairs)
        report["fatal_error"] = {"type": type(error).__name__, "message": safe_message[:1000]}
        print(f"Batch setup failed: {type(error).__name__}: {safe_message}", file=sys.stderr)
        return 1
    finally:
        report["finished_at"] = now()
        write_report(report, directory, announce=True)


if __name__ == "__main__":
    sys.exit(main())
