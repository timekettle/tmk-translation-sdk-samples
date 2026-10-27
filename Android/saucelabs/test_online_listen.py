"""Android online listening and on-device HTTPS PCM download test."""

from __future__ import annotations

import json
import math
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from saucelabs.quality_metrics import calculate_quality, collect_app_metrics, display_metric, display_percent  # noqa: E402
from saucelabs.remote_audio_probe import (  # noqa: E402
    configured_url, redact_url, wait_and_verify,
)

from appium import webdriver
from appium.options.android import UiAutomator2Options
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait

APP_ENV_PREFIX = "TMK_DEVICE_ENV="
# Paste your OSS HTTPS URL here, or set SAUCE_TEST_PCM_URL in the shell.
# Keep signed URLs out of Git; the environment variable is safer.
TEST_PCM_URL = "PASTE_HTTPS_PCM_URL_HERE"
ADDRESS_FIELDS = (
    "country", "country_code", "state_province", "county", "city",
    "district", "street", "street_number", "postal_code",
)


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"Set {name} before running this test")
    return value


def node_labels(element: ET.Element) -> tuple[str, str]:
    return element.attrib.get("content-desc", ""), element.attrib.get("text", "")


def label_matches(element: ET.Element, value: str) -> bool:
    return any(value in label.splitlines() for label in node_labels(element))


def has_label(page_source: str, value: str) -> bool:
    return any(label_matches(element, value) for element in ET.fromstring(page_source).iter())


def is_flutter_sample(page_source: str) -> bool:
    return any(
        element.attrib.get("resource-id") in {"tmk.sauce.home.start", "tmk.sauce.listen.start"}
        for element in ET.fromstring(page_source).iter()
    )


def enabled_clickable_center(page_source: str, value: str) -> tuple[int, int] | None:
    root = ET.fromstring(page_source)
    parents = {child: parent for parent in root.iter() for child in parent}
    for element in root.iter():
        if not label_matches(element, value):
            continue
        current = element
        while current is not None:
            if current.attrib.get("clickable") == "true":
                if current.attrib.get("enabled") != "true":
                    break
                bounds = re.fullmatch(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", current.attrib.get("bounds", ""))
                if bounds:
                    left, top, right, bottom = map(int, bounds.groups())
                    return (left + right) // 2, (top + bottom) // 2
                break
            current = parents.get(current)
    return None


def home_language_pair(page_source: str) -> tuple[str, str] | None:
    root = ET.fromstring(page_source)
    parents = {child: parent for parent in root.iter() for child in parent}
    values = []
    for label in ("源语言", "目标语言"):
        # Recent Compose versions merge each language card into one accessibility node.
        card = next((node for node in root.iter()
                     if node.attrib.get("content-desc", "").startswith(label + "\n")), None)
        if card is not None:
            parts = card.attrib["content-desc"].splitlines()
            if len(parts) >= 3 and re.fullmatch(r"[A-Za-z]{2,3}[-_][A-Za-z]{2,4}", parts[-1]):
                values.append(parts[-1].replace("_", "-"))
                continue
        text_node = next((node for node in root.iter() if node.attrib.get("text") == label), None)
        parent = parents.get(text_node) if text_node is not None else None
        if parent is None:
            return None
        choices = [node.attrib["text"] for node in parent.iter() if node.attrib.get("text") and node.attrib["text"] != label]
        if len(choices) != 1:
            return None
        values.append(choices[0])
    return values[0], values[1]


def scroll_home_to_languages(driver, max_scrolls: int = 6) -> tuple[str, str]:
    for attempt in range(max_scrolls + 1):
        pair = home_language_pair(driver.page_source)
        if pair is not None:
            return pair
        if attempt == max_scrolls:
            break
        scroll_view = driver.find_element(
            AppiumBy.ANDROID_UIAUTOMATOR, "new UiSelector().scrollable(true)"
        )
        can_scroll_more = driver.execute_script(
            "mobile: scrollGesture",
            {"elementId": scroll_view.id, "direction": "down", "percent": 0.8},
        )
        print(f"TEST_SCROLL_HOME={attempt + 1},can_scroll_more={can_scroll_more}", flush=True)
        if can_scroll_more is False:
            pair = home_language_pair(driver.page_source)
            if pair is not None:
                return pair
            break
    raise RuntimeError("Language selectors were not visible after scrolling the home screen")


def click_when_enabled(driver, value: str, timeout: int = 60) -> None:
    x, y = WebDriverWait(driver, timeout, poll_frequency=1).until(
        lambda current: enabled_clickable_center(current.page_source, value)
    )
    driver.execute_script("mobile: clickGesture", {"x": x, "y": y})
    print(
        "TEST_GESTURE=" + json.dumps({"target": value, "x": x, "y": y}, ensure_ascii=False),
        flush=True,
    )


def result_counts(driver) -> tuple[int, int] | None:
    for element in ET.fromstring(driver.page_source).iter():
        match = next((found for label in node_labels(element)
                      if (found := re.search(r"识别(\d+)条，翻译(\d+)条", label))), None)
        if match:
            return int(match.group(1)), int(match.group(2))
    return None


def translated_result_counts(driver) -> tuple[int, int] | bool:
    counts = result_counts(driver)
    return counts if counts is not None and all(value > 0 for value in counts) else False


def listening_started(driver) -> bool:
    return enabled_clickable_center(driver.page_source, "停止收听") is not None


def valid_location(location: object) -> dict | None:
    if not isinstance(location, dict):
        return None
    latitude = location.get("latitude")
    longitude = location.get("longitude")
    if (isinstance(latitude, bool) or not isinstance(latitude, (int, float))
            or isinstance(longitude, bool) or not isinstance(longitude, (int, float))
            or not math.isfinite(latitude) or not math.isfinite(longitude)
            or not -90 <= latitude <= 90 or not -180 <= longitude <= 180
            or (latitude == 0 and longitude == 0)):
        return None
    result = {"latitude": latitude, "longitude": longitude}
    altitude = location.get("altitude")
    if (isinstance(altitude, (int, float)) and not isinstance(altitude, bool)
            and math.isfinite(altitude)):
        result["altitude"] = altitude
    return result


def requested_region_settings() -> dict:
    latitude = os.environ.get("SAUCE_TEST_LATITUDE", "").strip()
    longitude = os.environ.get("SAUCE_TEST_LONGITUDE", "").strip()
    if bool(latitude) != bool(longitude):
        raise ValueError("Set SAUCE_TEST_LATITUDE and SAUCE_TEST_LONGITUDE together")
    gps = None
    if latitude:
        try:
            gps = valid_location({"latitude": float(latitude), "longitude": float(longitude)})
        except ValueError:
            pass
        if gps is None:
            raise ValueError("SAUCE_TEST_LATITUDE/LONGITUDE must be valid coordinates")
    locale = os.environ.get("SAUCE_TEST_LOCALE", "").strip()
    if locale:
        match = re.fullmatch(r"([A-Za-z]{2,3})[-_]([A-Za-z]{2})", locale)
        if not match:
            raise ValueError("SAUCE_TEST_LOCALE must look like fr_FR or en_US")
        locale = f"{match.group(1).lower()}_{match.group(2).upper()}"
    timezone_id = os.environ.get("SAUCE_TEST_TIMEZONE", "").strip()
    if timezone_id and not re.fullmatch(r"[A-Za-z0-9_+./-]{1,80}", timezone_id):
        raise ValueError("SAUCE_TEST_TIMEZONE must be a time zone identifier")
    return {"gps": gps, "locale": locale or None, "timezone": timezone_id or None}


def gps_distance_km(left: dict, right: dict) -> float:
    latitude1, longitude1 = math.radians(left["latitude"]), math.radians(left["longitude"])
    latitude2, longitude2 = math.radians(right["latitude"]), math.radians(right["longitude"])
    delta_latitude = latitude2 - latitude1
    delta_longitude = longitude2 - longitude1
    haversine = (math.sin(delta_latitude / 2) ** 2
                 + math.cos(latitude1) * math.cos(latitude2)
                 * math.sin(delta_longitude / 2) ** 2)
    return 6371.0 * 2 * math.asin(min(1.0, math.sqrt(haversine)))


def readable_address(value: object) -> dict | None:
    if not isinstance(value, dict):
        return None
    address = {}
    for key in ADDRESS_FIELDS:
        field = value.get(key)
        if isinstance(field, str):
            cleaned = " ".join(field.split())[:120]
            if cleaned:
                address[key] = cleaned
    return address or None


def address_summary(address: dict | None) -> str | None:
    if not address:
        return None
    parts = []
    for key in ("country", "state_province", "county", "city", "district", "street"):
        value = address.get(key)
        if value and value not in parts:
            parts.append(value)
    if address.get("street_number"):
        parts.append(address["street_number"])
    return " / ".join(parts) or None


def error_detail(error: Exception) -> str:
    first_line = str(error).strip().splitlines()[0:1]
    detail = first_line[0] if first_line else type(error).__name__
    for secret in (os.environ.get("SAUCE_ACCESS_KEY"), os.environ.get("SAUCE_USERNAME")):
        if secret:
            detail = detail.replace(secret, "[REDACTED]")
    return detail[:300]


def parse_app_device_environment(page_source: str) -> dict | None:
    root = ET.fromstring(page_source)
    for element in root.iter():
        for value in element.attrib.values():
            position = value.find(APP_ENV_PREFIX)
            if position < 0:
                continue
            try:
                payload, _ = json.JSONDecoder().raw_decode(value[position + len(APP_ENV_PREFIX):])
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and isinstance(payload.get("status"), str):
                return payload
    return None


def wait_for_app_device_environment(driver) -> dict | None:
    first_deadline = time.monotonic() + 5
    while time.monotonic() < first_deadline:
        payload = parse_app_device_environment(driver.page_source)
        if payload is not None:
            break
        time.sleep(1)
    else:
        return None
    deadline = time.monotonic() + 35
    while payload.get("status") in {"pending", "not_requested"} and time.monotonic() < deadline:
        time.sleep(1)
        payload = parse_app_device_environment(driver.page_source) or payload
    return payload


def test_environment(driver, region: str) -> dict:
    """Read Appium settings, then prefer location measured from inside the Sample."""
    capabilities = driver.capabilities
    environment = {
        "sauce_data_center": region,
        "session_id": driver.session_id,
        "device_name": capabilities.get("deviceName") or capabilities.get("appium:deviceName"),
        "device_locale": capabilities.get("locale") or capabilities.get("appium:locale"),
        "device_language": capabilities.get("language") or capabilities.get("appium:language"),
        "device_timezone": capabilities.get("timeZone") or capabilities.get("appium:timeZone"),
        "gps": None,
        "gps_source": None,
        "gps_accuracy_m": None,
        "address": None,
        "address_summary": None,
        "geocode_status": None,
        "app_device_locale": None,
        "app_device_timezone": None,
        "app_location_status": None,
        "sample_network_environment": None,
        "capture_errors": {},
    }
    try:
        device_info = driver.execute_script("mobile: deviceInfo")
        locale = device_info.get("locale") if isinstance(device_info, dict) else None
        environment["device_locale"] = locale or environment["device_locale"]
        if isinstance(locale, str):
            environment["device_language"] = re.split(r"[-_]", locale, maxsplit=1)[0]
        environment["device_timezone"] = (
            (device_info.get("timeZone") if isinstance(device_info, dict) else None)
            or environment["device_timezone"]
        )
    except Exception as error:
        environment["capture_errors"]["device_info"] = type(error).__name__
        environment["capture_errors"]["device_info_detail"] = error_detail(error)

    try:
        environment["gps"] = valid_location(driver.location)
        if environment["gps"]:
            environment["gps_source"] = "appium_location"
    except Exception as error:
        environment["capture_errors"]["gps"] = type(error).__name__
        environment["capture_errors"]["gps_detail"] = error_detail(error)
    try:
        first_deadline = time.monotonic() + 5
        button_center = None
        while time.monotonic() < first_deadline:
            button_center = enabled_clickable_center(driver.page_source, "读取设备定位")
            if button_center is not None:
                break
            time.sleep(1)
        if button_center is not None:
            driver.execute_script("mobile: clickGesture", {"x": button_center[0], "y": button_center[1]})
        app_info = wait_for_app_device_environment(driver)
        if app_info:
            environment["app_device_locale"] = app_info.get("locale")
            environment["app_device_timezone"] = app_info.get("timeZone")
            environment["app_location_status"] = app_info["status"]
            environment["sample_network_environment"] = app_info.get("sample_network_environment")
            app_gps = valid_location(app_info.get("gps"))
            if app_gps and app_info["status"] == "ok":
                environment["gps"] = app_gps
                environment["gps_source"] = "app_android_location"
                environment["gps_accuracy_m"] = (app_info.get("gps") or {}).get("horizontal_accuracy_m")
                environment["geocode_status"] = app_info.get("geocode_status")
                environment["address"] = readable_address(app_info.get("address"))
                environment["address_summary"] = address_summary(environment["address"])
                if environment["geocode_status"] not in (None, "ok"):
                    environment["capture_errors"]["reverse_geocode"] = environment["geocode_status"]
                    if app_info.get("geocode_detail"):
                        environment["capture_errors"]["reverse_geocode_detail"] = str(app_info["geocode_detail"])[:300]
            else:
                environment["capture_errors"]["app_gps"] = (
                    "invalid_location" if app_info["status"] == "ok" else app_info["status"]
                )
                if app_info.get("detail"):
                    environment["capture_errors"]["app_gps_detail"] = str(app_info["detail"])[:300]
    except Exception as error:
        environment["capture_errors"]["app_device_info"] = type(error).__name__
        environment["capture_errors"]["app_device_info_detail"] = error_detail(error)
    return environment


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def report_directory(run_id: str) -> Path:
    safe_id = re.sub(r"[^A-Za-z0-9_-]", "_", run_id)
    return Path(__file__).resolve().parent / "artifacts" / safe_id


def write_report(report: dict, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "report.json"
    markdown_path = output_dir / "report.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    environment = report.get("environment") or {}
    counts = report.get("result_counts") or {}
    quality = report.get("quality_metrics") or {}
    lines = [
        "# Android 在线收听云测报告",
        "",
        f"- 结果：{'通过' if report['status'] == 'passed' else '失败'}",
        f"- Sauce 会话：`{report.get('session_id') or '未创建'}`",
        f"- 数据中心：`{report.get('sauce_data_center') or '未知'}`",
        f"- 目标地区设置：`{json.dumps(report.get('region_target'), ensure_ascii=False)}`",
        f"- 设备：`{environment.get('device_name') or '未知'}`",
        f"- 系统语言：`{environment.get('device_locale') or '未知'}`",
        f"- 时区：`{environment.get('device_timezone') or '未知'}`",
        f"- App 语言区域：`{environment.get('app_device_locale') or '未取得'}`",
        f"- App 时区：`{environment.get('app_device_timezone') or '未取得'}`",
        f"- Sample SDK 网络环境：`{environment.get('sample_network_environment') or '未取得'}`",
        f"- GPS：`{json.dumps(environment.get('gps'), ensure_ascii=False)}`",
        f"- GPS 来源：`{environment.get('gps_source') or '未取得'}`",
        f"- GPS 水平精度：`{environment.get('gps_accuracy_m') if environment.get('gps_accuracy_m') is not None else '未取得'}` 米",
        f"- 位置：`{environment.get('address_summary') or '未取得'}`",
        f"- 国家/地区：`{(environment.get('address') or {}).get('country') or '未取得'}`",
        f"- 州/省：`{(environment.get('address') or {}).get('state_province') or '未取得'}`",
        f"- 城市：`{(environment.get('address') or {}).get('city') or '未取得'}`",
        f"- 街道：`{(environment.get('address') or {}).get('street') or '未取得'}`",
        f"- 地址解析状态：`{environment.get('geocode_status') or '未取得'}`",
        f"- App 定位状态：`{environment.get('app_location_status') or '未取得'}`",
        "- App 翻译方向：`en-US → zh-CN`",
        f"- 音频来源：`{report.get('audio_source')}`",
        f"- 仅验证下载：`{report.get('download_only')}`",
        f"- 开始：`{report['started_at']}`",
        f"- 结束：`{report['finished_at']}`",
        f"- 耗时：`{report['duration_seconds']}` 秒",
        f"- ASR 条数：`{counts.get('asr', '未取得')}`",
        f"- 翻译条数：`{counts.get('translation', '未取得')}`",
        "",
        "## App 自行下载 PCM",
        "",
        f"- 结果：`{json.dumps(report.get('download'), ensure_ascii=False)}`",
        "- 校验：HTTP 200、679254 字节、SHA-256 与本地原始 PCM 一致。",
        "",
        "## 质量指标",
        "",
        f"- 首个 ASR 文本回调：`{display_metric(quality.get('first_asr_ms'))}` ms",
        f"- 首个 MT 文本回调：`{display_metric(quality.get('first_mt_ms'))}` ms",
        f"- 首个音频回调（含静音）：`{display_metric(quality.get('first_audio_callback_ms'))}` ms",
        f"- 首个有声 TTS PCM 包回调：`{display_metric(quality.get('first_tts_packet_ms'))}` ms",
        f"- WER：`{display_percent((quality.get('asr') or {}).get('wer_percent'))}`",
        f"- CER：`{display_percent((quality.get('asr') or {}).get('cer_percent'))}`",
        f"- ASR 准确度（100 − WER）：`{display_percent((quality.get('asr') or {}).get('accuracy_percent'))}`",
        f"- 翻译语义匹配度：`{display_percent(((quality.get('translation') or {}).get('match') or {}).get('percent'))}`",
        f"- 翻译评分状态：`{((quality.get('translation') or {}).get('match') or {}).get('status', '未取得')}`",
        "- 时延起点：第一帧测试 PCM 推入 SDK；TTS 首包为 SDK 回调，并非扬声器实际出声。",
        "",
        "### 文本",
        "",
        f"- 人工原文：{(quality.get('asr') or {}).get('reference_text', '未取得')}",
        f"- ASR 最终文本：{(quality.get('asr') or {}).get('recognized_text', '未取得')}",
        f"- MT 最终文本：{(quality.get('translation') or {}).get('translated_text', '未取得')}",
        "",
        "## 执行步骤",
        "",
    ]
    lines.extend(f"- {item['at']}：{item['name']}" for item in report["steps"])
    if report.get("failure"):
        failure = report["failure"]
        lines.extend([
            "",
            "## 失败原因",
            "",
            f"步骤：{failure['step']}",
            "",
            f"异常：`{failure['type']}`",
            "",
            "```text",
            failure["message"],
            "```",
        ])
    diagnostics = report.get("diagnostics") or {}
    if diagnostics:
        lines.extend(["", "## 诊断文件", ""])
        lines.extend(f"- {name}：`{path}`" for name, path in diagnostics.items())
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("TEST_REPORT=" + json.dumps({"json": str(json_path), "markdown": str(markdown_path)}, ensure_ascii=False), flush=True)


def capture_failure_artifacts(driver, output_dir: Path, remote_url: str | None = None) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    results = {}
    try:
        screenshot = output_dir / "failure.png"
        if driver.save_screenshot(str(screenshot)):
            results["screenshot"] = str(screenshot)
    except Exception as error:
        results["screenshot_error"] = type(error).__name__
    try:
        page_source = output_dir / "page.xml"
        page_source.write_text(redact_url(driver.page_source, remote_url), encoding="utf-8")
        results["page_source"] = str(page_source)
    except Exception as error:
        results["page_source_error"] = type(error).__name__
    print("TEST_DIAGNOSTICS=" + json.dumps(results, ensure_ascii=False), flush=True)
    return results


def main() -> int:
    started = time.monotonic()
    run_id = f"setup-{uuid4()}"
    region = os.environ.get("SAUCE_REGION", "us-west-1").strip()
    download_only = os.environ.get("SAUCE_DOWNLOAD_ONLY", "0").strip() == "1"
    remote_url = None
    report = {
        "test": "Android online listen / app HTTPS PCM download",
        "status": "failed",
        "session_id": None,
        "sauce_data_center": region,
        "region_target": None,
        "started_at": utc_now(),
        "finished_at": None,
        "duration_seconds": None,
        "environment": None,
        "steps": [],
        "result_counts": None,
        "quality_metrics": None,
        "audio_source": "bundled_pcm",
        "download_only": download_only,
        "download": None,
        "failure": None,
        "diagnostics": {},
    }
    driver = None
    passed = False
    step = "创建 Sauce 会话"

    def start_step(name: str) -> None:
        nonlocal step
        step = name
        report["steps"].append({"name": name, "at": utc_now()})
        print(f"TEST_STEP={name}", flush=True)

    try:
        start_step("校验远程音频 URL")
        remote_url = configured_url(TEST_PCM_URL, required=download_only)
        if remote_url:
            report["audio_source"] = "app_https_download"
        start_step("创建 Sauce 会话")
        username = required("SAUCE_USERNAME")
        access_key = required("SAUCE_ACCESS_KEY")
        app = required("SAUCE_APP")
        device_name = required("SAUCE_DEVICE_NAME")
        if region not in {"us-west-1", "us-east-4", "eu-central-1", "asia-south-2"}:
            raise ValueError("SAUCE_REGION must be a Sauce Labs data center ID")
        if not app.startswith("storage:"):
            raise ValueError("SAUCE_APP must be a Sauce App Storage reference, such as storage:<file-id>")
        region_target = requested_region_settings()
        report["region_target"] = region_target

        capabilities = {
            "platformName": "Android",
            "appium:automationName": "UiAutomator2",
            "appium:app": app,
            "appium:deviceName": device_name,
            "appium:autoGrantPermissions": True,
            "sauce:options": {
                "username": username,
                "accessKey": access_key,
                "name": report["test"],
                "appiumVersion": os.environ.get("SAUCE_APPIUM_VERSION", "latest").strip() or "latest",
            },
        }
        if region_target["locale"]:
            language, country = region_target["locale"].split("_")
            capabilities["appium:language"] = language
            capabilities["appium:locale"] = country
        if region_target["timezone"]:
            capabilities["appium:timeZone"] = region_target["timezone"]
        if build := os.environ.get("SAUCE_BUILD"):
            capabilities["sauce:options"]["build"] = build

        endpoint = f"https://ondemand.{region}.saucelabs.com/wd/hub"
        driver = webdriver.Remote(
            command_executor=endpoint,
            options=UiAutomator2Options().load_capabilities(capabilities),
        )
        report["session_id"] = driver.session_id
        run_id = driver.session_id or run_id
        start_step("核对安装包类型")
        if is_flutter_sample(driver.page_source):
            raise RuntimeError(
                "SAUCE_APP 指向 Flutter Android Sample；请改用 "
                "Flutter/apps/tmk_translation_demo/saucelabs/test_online_listen.py，"
                "或上传原生 Android APK 并更新 SAUCE_APP"
            )
        if region_target["gps"]:
            start_step("设置模拟 GPS")
            driver.set_location(
                region_target["gps"]["latitude"], region_target["gps"]["longitude"]
            )
        start_step("读取设备环境")
        report["environment"] = (
            {
                "sauce_data_center": region,
                "session_id": driver.session_id,
                "device_name": driver.capabilities.get("deviceName")
                    or driver.capabilities.get("appium:deviceName"),
                "capture_errors": {},
            }
            if download_only else test_environment(driver, region)
        )
        report["environment"]["region_target"] = region_target
        if not download_only and region_target["gps"] and report["environment"]["gps"]:
            report["environment"]["gps_target_distance_km"] = round(
                gps_distance_km(region_target["gps"], report["environment"]["gps"]), 2
            )
        print(
            "TEST_ENVIRONMENT=" + json.dumps(report["environment"], ensure_ascii=False),
            flush=True,
        )
        if not download_only and any(region_target.values()):
            start_step("校验目标地区信号")
            measured = report["environment"]
            if region_target["gps"]:
                if measured["gps_source"] != "app_android_location":
                    raise RuntimeError("Could not verify simulated GPS from inside the app")
                if measured["gps_target_distance_km"] > 50:
                    raise RuntimeError("App GPS is over 50 km from the requested test location")
            if region_target["locale"]:
                actual_locale = str(measured["app_device_locale"] or "").replace("-", "_")
                if actual_locale.lower() != region_target["locale"].lower():
                    raise RuntimeError(
                        f"App locale {actual_locale or 'unavailable'} differs from {region_target['locale']}"
                    )
            if (region_target["timezone"]
                    and measured["app_device_timezone"] != region_target["timezone"]):
                raise RuntimeError(
                    f"App time zone {measured['app_device_timezone'] or 'unavailable'} "
                    f"differs from {region_target['timezone']}"
                )
        # Home defaults to listening / online, with zh-CN -> en-US.
        start_step("滚动首页并读取语言方向")
        initial_pair = scroll_home_to_languages(driver)
        if initial_pair not in {
            ("简体", "美国"), ("美国", "简体"),
            ("zh-CN", "en-US"), ("en-US", "zh-CN"),
        }:
            raise ValueError(f"Unexpected home language pair: {initial_pair}")
        start_step("切换为英语→中文")
        if initial_pair[0] in {"简体", "zh-CN"}:
            click_when_enabled(driver, "⇄")  # Use the English recording: en-US -> zh-CN.
            start_step("确认语言方向已切换")
            WebDriverWait(driver, 20).until(
                lambda current: home_language_pair(current.page_source) == initial_pair[::-1]
            )
        start_step("进入在线翻译")
        click_when_enabled(driver, "开始在线翻译")
        start_step("确认已进入在线收听页")
        WebDriverWait(driver, 20).until(
            lambda current: has_label(current.page_source, "旁听模式（单声道）")
        )
        start_step("选择测试音频")
        click_when_enabled(driver, "测试音频")
        start_step("确认测试音频已选中")
        WebDriverWait(driver, 20).until(lambda current: result_counts(current) is not None)
        if remote_url:
            start_step("将 HTTPS URL 输入 App")
            try:
                field = driver.find_element(AppiumBy.ACCESSIBILITY_ID, "tmk.sauce.listen.remoteUrl")
            except Exception:
                field = driver.find_element(
                    AppiumBy.ANDROID_UIAUTOMATOR,
                    'new UiSelector().className("android.widget.EditText")',
                )
            field.send_keys(remote_url)
            try:
                driver.hide_keyboard()
            except Exception:
                pass
            start_step("让 App 从 HTTPS 下载 PCM")
            click_when_enabled(driver, "下载测试音频")
            start_step("校验 App 下载的字节数和 SHA-256")
            report["download"] = wait_and_verify(driver, report)
            if download_only:
                passed = True
                report["status"] = "passed"
                return 0
        start_step("等待开始收听按钮可用")
        click_when_enabled(driver, "开始收听", timeout=120)
        start_step("确认收听已开始")
        WebDriverWait(driver, 15).until(listening_started)

        start_step("等待测试音频推送完毕")
        WebDriverWait(driver, 60).until(
            lambda current: has_label(current.page_source, "测试音频已推送完毕")
        )
        start_step("等待识别和翻译结果")
        counts = WebDriverWait(driver, 90).until(translated_result_counts)
        report["result_counts"] = {"asr": counts[0], "translation": counts[1]}
        print(f"Received online listening results: ASR={counts[0]}, translation={counts[1]}")
        start_step("采集首字首包与最终文本")
        report["quality_metrics"] = calculate_quality(collect_app_metrics(driver))
        print("TEST_QUALITY=" + json.dumps({
            "first_asr_ms": report["quality_metrics"]["first_asr_ms"],
            "first_mt_ms": report["quality_metrics"]["first_mt_ms"],
            "first_audio_callback_ms": report["quality_metrics"]["first_audio_callback_ms"],
            "first_tts_packet_ms": report["quality_metrics"]["first_tts_packet_ms"],
            "wer_percent": report["quality_metrics"]["asr"]["wer_percent"],
            "cer_percent": report["quality_metrics"]["asr"]["cer_percent"],
            "accuracy_percent": report["quality_metrics"]["asr"]["accuracy_percent"],
            "translation_match_percent": report["quality_metrics"]["translation"]["match"]["percent"],
        }), flush=True)
        if report["quality_metrics"]["translation"]["match"]["status"] != "scored":
            raise RuntimeError("Translation quality scoring unavailable: " +
                               report["quality_metrics"]["translation"]["match"].get("reason", "unknown"))
        passed = True
        report["status"] = "passed"
        return 0
    except Exception as error:
        if driver is not None:
            try:
                report["diagnostics"] = capture_failure_artifacts(driver, report_directory(run_id), remote_url)
            except Exception as artifact_error:
                print(
                    f"Could not save diagnostics: {type(artifact_error).__name__}",
                    file=sys.stderr,
                )
        detail = redact_url(str(error).strip(), remote_url)
        for secret in (os.environ.get("SAUCE_ACCESS_KEY"), os.environ.get("SAUCE_USERNAME")):
            if secret:
                detail = detail.replace(secret, "[REDACTED]")
        report["failure"] = {"step": step, "type": type(error).__name__, "message": detail[:4000]}
        raise RuntimeError(
            f"{step} failed ({type(error).__name__})" + (f": {detail}" if detail else "")
        ) from error
    finally:
        if driver is not None:
            try:
                driver.execute_script(f"sauce:job-result={'passed' if passed else 'failed'}")
            except Exception as error:
                report["sauce_job_result_error"] = type(error).__name__
                print(f"Could not report Sauce job result: {type(error).__name__}", file=sys.stderr)
            try:
                driver.quit()
            except Exception as error:
                report["session_close_error"] = type(error).__name__
                print(f"Could not close Sauce session: {type(error).__name__}", file=sys.stderr)
        report["finished_at"] = utc_now()
        report["duration_seconds"] = round(time.monotonic() - started, 2)
        write_report(report, report_directory(run_id))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Online listening smoke test failed: {error}", file=sys.stderr)
        sys.exit(1)
