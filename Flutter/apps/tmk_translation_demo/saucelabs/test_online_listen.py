"""Sauce real-device smoke test for the Flutter sample's online listening mode."""

from __future__ import annotations

import json
import math
import os
import re
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[4]))
from saucelabs.quality_metrics import calculate_quality, collect_app_metrics, display_metric, display_percent  # noqa: E402
from saucelabs.remote_audio_probe import (  # noqa: E402
    configured_url, preflight_url, redact_url, wait_and_verify,
)

from appium import webdriver
from appium.options.common import AppiumOptions
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
_INSTALLED_LOCAL_APKS: set[tuple[str, str, int]] = set()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"Set {name} before running this test")
    return value


def test_backend() -> str:
    backend = os.environ.get("TEST_BACKEND", "sauce").strip().lower()
    if backend not in {"sauce", "local"}:
        raise ValueError("TEST_BACKEND must be sauce or local")
    return backend


def test_platform() -> str:
    platform = os.environ.get("TEST_PLATFORM", os.environ.get("SAUCE_PLATFORM", "Android")).strip()
    if platform not in {"Android", "iOS"}:
        raise ValueError("TEST_PLATFORM must be Android or iOS")
    return platform


def local_app_path(platform: str) -> Path:
    default = (Path(__file__).resolve().parents[1] / "build/app/outputs/flutter-apk/app-debug.apk"
               if platform == "Android" else None)
    configured = os.environ.get("LOCAL_APP_PATH", "").strip()
    if not configured and default is None:
        raise ValueError("Set LOCAL_APP_PATH to a development-signed iOS IPA")
    path = Path(configured).expanduser().resolve() if configured else default
    if not path.is_file() or path.suffix.lower() != (".apk" if platform == "Android" else ".ipa"):
        raise ValueError(f"LOCAL_APP_PATH must point to an existing {platform} installable package")
    return path


def validate_session_setup(platform: str, region: str, backend: str) -> None:
    if backend == "sauce":
        if region not in {"us-west-1", "us-east-4", "eu-central-1", "asia-south-2"}:
            raise ValueError("SAUCE_REGION must be a Sauce Labs data center ID")
        if not required("SAUCE_APP").startswith("storage:"):
            raise ValueError("SAUCE_APP must be a Sauce App Storage reference")
        required("SAUCE_USERNAME")
        required("SAUCE_ACCESS_KEY")
        required("SAUCE_DEVICE_NAME")
    else:
        required("LOCAL_DEVICE_UDID")
        local_app_path(platform)
        endpoint = os.environ.get("APPIUM_SERVER_URL", "http://127.0.0.1:4723").strip().rstrip("/")
        parsed = urlsplit(endpoint)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError("APPIUM_SERVER_URL must be an HTTP(S) Appium endpoint")


def install_local_android_apk(udid: str, apk: Path) -> None:
    """Update the exact APK before noReset can reuse a stale same-package app."""
    install_key = (udid, str(apk), apk.stat().st_mtime_ns)
    if install_key in _INSTALLED_LOCAL_APKS:
        return
    try:
        result = subprocess.run(
            ["adb", "-s", udid, "install", "-r", str(apk)],
            capture_output=True, text=True, timeout=180, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"Could not install local Android APK with adb: {error}") from error
    if result.returncode != 0 or "Success" not in result.stdout:
        detail = (result.stderr or result.stdout).strip()
        if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in detail:
            detail += (". The installed app has a different signature; remove it only "
                       "if its local data can be discarded, then retry")
        raise RuntimeError(f"Local APK install failed: {detail}")
    _INSTALLED_LOCAL_APKS.add(install_key)
    print("TEST_LOCAL_APK_INSTALL=ok", flush=True)


def create_test_driver(platform: str, region: str, backend: str,
                       region_target: dict, name: str):
    validate_session_setup(platform, region, backend)
    if backend == "sauce":
        capabilities = {
            "platformName": platform,
            "appium:automationName": "UiAutomator2" if platform == "Android" else "XCUITest",
            "appium:app": required("SAUCE_APP"),
            "appium:deviceName": required("SAUCE_DEVICE_NAME"),
            "sauce:options": {
                "username": required("SAUCE_USERNAME"),
                "accessKey": required("SAUCE_ACCESS_KEY"),
                "name": name,
                "appiumVersion": os.environ.get("SAUCE_APPIUM_VERSION", "latest").strip() or "latest",
            },
        }
        if build := os.environ.get("SAUCE_BUILD"):
            capabilities["sauce:options"]["build"] = build
        endpoint = f"https://ondemand.{region}.saucelabs.com/wd/hub"
    else:
        app_path = local_app_path(platform)
        udid = required("LOCAL_DEVICE_UDID")
        if platform == "Android":
            install_local_android_apk(udid, app_path)
        capabilities = {
            "platformName": platform,
            "appium:automationName": "UiAutomator2" if platform == "Android" else "XCUITest",
            "appium:app": str(app_path),
            "appium:udid": udid,
            "appium:deviceName": os.environ.get("LOCAL_DEVICE_NAME", platform).strip() or platform,
            "appium:noReset": True,
        }
        if platform == "iOS":
            if team_id := os.environ.get("LOCAL_IOS_TEAM_ID", "").strip():
                capabilities["appium:xcodeOrgId"] = team_id
                capabilities["appium:xcodeSigningId"] = "Apple Development"
            if wda_bundle := os.environ.get("LOCAL_WDA_BUNDLE_ID", "").strip():
                capabilities["appium:updatedWDABundleId"] = wda_bundle
        endpoint = os.environ.get("APPIUM_SERVER_URL", "http://127.0.0.1:4723").strip().rstrip("/")
    if platform == "Android":
        capabilities["appium:autoGrantPermissions"] = True
    if region_target["locale"]:
        language, country = region_target["locale"].split("_")
        capabilities["appium:language"] = language
        capabilities["appium:locale"] = country if platform == "Android" else region_target["locale"]
    if region_target["timezone"]:
        capabilities["appium:timeZone" if platform == "Android" else "appium:appTimeZone"] = \
            region_target["timezone"]
    driver = webdriver.Remote(
        command_executor=endpoint,
        options=AppiumOptions().load_capabilities(capabilities),
    )
    if region_target["gps"]:
        try:
            driver.set_location(region_target["gps"]["latitude"],
                                region_target["gps"]["longitude"])
        except Exception:
            driver.quit()
            raise
    return driver


def output_directory(run_id: str) -> Path:
    safe_id = re.sub(r"[^A-Za-z0-9_-]", "_", run_id)
    return Path(__file__).resolve().parent / "artifacts" / safe_id


def visible_text_elements(driver, value: str, *, exact: bool = True) -> list:
    # Flutter exposes Text/ChoiceChip labels to UiAutomator2 and XCUITest.
    literal = f'"{value}"'
    if exact:
        predicate = (
            f"@text={literal} or @label={literal} or @name={literal} "
            f"or @content-desc={literal}"
        )
    else:
        predicate = " or ".join(
            f"contains(@{attribute}, {literal})"
            for attribute in ("text", "label", "name", "content-desc")
        )
    return [
        element
        for element in driver.find_elements(AppiumBy.XPATH, f"//*[{predicate}]")
        if element.is_displayed()
    ]


def identifier_elements(driver, identifier: str, platform: str) -> list:
    if platform == "Android":
        elements = driver.find_elements(
            AppiumBy.XPATH, f'//*[@resource-id="{identifier}"]'
        )
    else:
        elements = driver.find_elements(AppiumBy.ACCESSIBILITY_ID, identifier)
    return [element for element in elements if element.is_displayed()]


def control_elements(driver, identifier: str, label: str, platform: str) -> list:
    return identifier_elements(driver, identifier, platform) or visible_text_elements(driver, label)


def click_control(driver, identifier: str, label: str, platform: str, timeout: int = 30) -> None:
    element = WebDriverWait(driver, timeout, poll_frequency=1).until(
        lambda current: next(
            (
                item
                for item in control_elements(current, identifier, label, platform)
                if item.is_enabled()
            ),
            None,
        )
    )
    element.click()


def download_button(driver, platform: str):
    # On Android the Semantics identifier belongs to a non-clickable wrapper.
    # The actual FilledButton is its child and exposes the enabled state.
    if platform == "Android":
        elements = driver.find_elements(
            AppiumBy.XPATH,
            '//*[@resource-id="tmk.sauce.listen.download"]//android.widget.Button',
        )
    else:
        elements = driver.find_elements(
            AppiumBy.XPATH,
            '//XCUIElementTypeButton[@label="下载测试音频" or @name="下载测试音频"]',
        ) or visible_text_elements(driver, "下载测试音频")
    return next((item for item in elements if item.is_displayed()), None)


def enter_remote_url(driver, remote_url: str, platform: str) -> str:
    # Android's `mobile: type` turns each '&' into '&-' in this Flutter field.
    # That changes OSS signed query parameters and makes every GET return 403.
    methods = ("send_keys",)
    failures = []
    for method in methods:
        try:
            fields = identifier_elements(driver, "tmk.sauce.listen.remoteUrl", platform)
            if not fields:
                raise RuntimeError("App 的 HTTPS PCM URL 输入框不可见")
            field = fields[0]
            field.clear()
            field.click()
            field.send_keys(remote_url)
            WebDriverWait(driver, 6, poll_frequency=1).until(
                lambda current: (button := download_button(current, platform))
                and button.is_enabled()
            )
            try:
                driver.hide_keyboard()
            except Exception:
                pass
            button = download_button(driver, platform)
            if button and button.is_enabled():
                print("TEST_DOWNLOAD_INPUT=" + json.dumps({
                    "method": method, "button_enabled": True,
                }), flush=True)
                return method
            failures.append(f"{method}: 键盘收起后下载按钮仍禁用")
        except Exception as exc:
            # Appium errors may echo command arguments, including a signed URL.
            failures.append(f"{method}: {type(exc).__name__}")
    raise RuntimeError("HTTPS URL 未进入 App 输入框，下载按钮保持禁用；"
                       + "; ".join(failures))


def scroll_home_to_languages(driver, platform: str) -> None:
    for attempt in range(7):
        # iOS exposes each language card as one label, such as "源语言\n简体\nzh-CN".
        if (
            visible_text_elements(driver, "zh-CN", exact=False)
            and visible_text_elements(driver, "en-US", exact=False)
            and control_elements(driver, "tmk.sauce.home.swap", "⇄", platform)
        ):
            return
        if attempt == 6:
            break
        if platform == "Android":
            scrollable = driver.find_element(
                AppiumBy.ANDROID_UIAUTOMATOR, "new UiSelector().scrollable(true)"
            )
            driver.execute_script(
                "mobile: scrollGesture",
                {"elementId": scrollable.id, "direction": "down", "percent": 0.8},
            )
        else:
            driver.execute_script("mobile: scroll", {"direction": "down"})
    raise RuntimeError("Could not find the default zh-CN/en-US language selectors")


def result_counts(driver, platform: str) -> tuple[int, int] | None:
    elements = identifier_elements(driver, "tmk.sauce.listen.counts", platform)
    if not elements:
        elements = visible_text_elements(driver, "测试观察：", exact=False)
    for element in elements:
        attribute = "content-desc" if platform == "Android" else "label"
        for label in (element.text or "", element.get_attribute(attribute) or ""):
            match = re.search(r"测试观察：识别(\d+)条，翻译(\d+)条", label)
            if match:
                return int(match.group(1)), int(match.group(2))
    return None


def received_results(driver, platform: str) -> tuple[int, int] | bool:
    counts = result_counts(driver, platform)
    return counts if counts and all(count > 0 for count in counts) else False


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


def accept_ios_location_alert(driver) -> str | None:
    """Accept only the app's location prompt, never a different system alert."""
    try:
        buttons = driver.execute_script("mobile: alert", {"action": "getButtons"})
    except Exception:
        # Some Sauce Appium images do not expose the execute extension. The
        # iOS accessibility tree still exposes alert buttons as native elements.
        buttons = None
    preferred = (
        "Allow While Using App",
        "Allow Once",
        "使用 App 期间允许",
        "使用App期间允许",
        "仅允许一次",
    )
    for label in preferred:
        if buttons is not None and label in buttons:
            driver.execute_script(
                "mobile: alert", {"action": "accept", "buttonLabel": label}
            )
            print(f"TEST_PERMISSION=定位授权：{label}", flush=True)
            return label
    if buttons is None:
        elements = driver.find_elements(
            AppiumBy.XPATH, "//XCUIElementTypeAlert//XCUIElementTypeButton"
        )
        for label in preferred:
            for element in elements:
                if element.get_attribute("label") == label and element.is_displayed():
                    element.click()
                    print(f"TEST_PERMISSION=定位授权：{label}", flush=True)
                    return label
    return None


def wait_for_app_device_environment(driver, platform: str) -> dict | None:
    # Older IPAs lack the opt-in diagnostic element; do not delay their test runs.
    first_deadline = time.monotonic() + 5
    while time.monotonic() < first_deadline:
        if platform == "iOS":
            accept_ios_location_alert(driver)
        payload = parse_app_device_environment(driver.page_source)
        if payload is not None:
            break
        time.sleep(1)
    else:
        return None
    deadline = time.monotonic() + 35
    while payload.get("status") in {"pending", "not_requested"} and time.monotonic() < deadline:
        if platform == "iOS":
            accept_ios_location_alert(driver)
        time.sleep(1)
        payload = parse_app_device_environment(driver.page_source) or payload
    return payload


def device_environment(driver, platform: str, region: str,
                       backend: str = "sauce") -> dict:
    capabilities = driver.capabilities
    environment = {
        "platform": platform,
        "execution_backend": backend,
        "sauce_data_center": region if backend == "sauce" else None,
        "session_id": driver.session_id,
        "device_name": capabilities.get("deviceName") or capabilities.get("appium:deviceName"),
        "device_udid": capabilities.get("udid") or capabilities.get("appium:udid"),
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
        "app_location_source": None,
        "app_location_age_ms": None,
        "app_location_permission": None,
        "app_precision_status": None,
        "app_location_providers": None,
        "gps_consistency_distance_km": None,
        "sample_network_environment": None,
        "capture_errors": {},
    }
    try:
        info = driver.execute_script("mobile: deviceInfo")
        if isinstance(info, dict):
            environment["device_locale"] = (info.get("currentLocale") or info.get("locale")
                                            or environment["device_locale"])
            environment["device_timezone"] = info.get("timeZone") or environment["device_timezone"]
    except Exception as error:
        environment["capture_errors"]["device_info"] = type(error).__name__
        environment["capture_errors"]["device_info_detail"] = error_detail(error)
    if not environment["device_language"] and environment["device_locale"]:
        environment["device_language"] = re.split(
            r"[-_]", environment["device_locale"], maxsplit=1
        )[0]
    try:
        environment["gps"] = valid_location(driver.location)
        if environment["gps"]:
            environment["gps_source"] = "appium_location"
    except Exception as error:
        environment["capture_errors"]["gps"] = type(error).__name__
        environment["capture_errors"]["gps_detail"] = error_detail(error)
    if platform == "iOS" and environment["gps"] is None:
        try:
            environment["gps"] = valid_location(driver.execute_script("mobile: getSimulatedLocation"))
            if environment["gps"]:
                environment["gps_source"] = "appium_simulated_location"
        except Exception as error:
            environment["capture_errors"]["simulated_gps"] = type(error).__name__
            environment["capture_errors"]["simulated_gps_detail"] = error_detail(error)
    if platform in {"Android", "iOS"}:
        try:
            # A preexisting IPA may already have opened the prompt during session creation.
            if platform == "iOS":
                accept_ios_location_alert(driver)
            request_buttons = identifier_elements(
                driver, "tmk.sauce.home.requestLocation", platform
            )
            if request_buttons:
                request_buttons[0].click()
            app_info = wait_for_app_device_environment(driver, platform)
            if app_info:
                environment["app_device_locale"] = app_info.get("locale")
                environment["app_device_timezone"] = app_info.get("timeZone")
                environment["app_location_status"] = app_info["status"]
                environment["app_location_source"] = app_info.get("location_source")
                environment["app_location_age_ms"] = app_info.get("location_age_ms")
                environment["app_location_permission"] = app_info.get("location_permission")
                environment["app_precision_status"] = app_info.get("precision_status")
                environment["app_location_providers"] = app_info.get("providers")
                environment["sample_network_environment"] = app_info.get("sample_network_environment")
                app_gps = valid_location(app_info.get("gps"))
                if app_gps and app_info["status"] == "ok":
                    appium_gps = environment["gps"]
                    environment["gps"] = app_gps
                    environment["gps_source"] = (
                        "app_core_location" if platform == "iOS" else "app_android_location"
                    )
                    environment["gps_accuracy_m"] = (app_info.get("gps") or {}).get(
                        "horizontal_accuracy_m"
                    )
                    environment["geocode_status"] = app_info.get("geocode_status")
                    environment["address"] = readable_address(app_info.get("address"))
                    environment["address_summary"] = address_summary(environment["address"])
                    if appium_gps:
                        distance = round(gps_distance_km(appium_gps, app_gps), 2)
                        environment["gps_consistency_distance_km"] = distance
                        if distance > 50:
                            environment["capture_errors"]["app_gps_mismatch"] = (
                                f"App and Appium locations differ by {distance} km"
                            )
                    if environment["geocode_status"] not in (None, "ok"):
                        environment["capture_errors"]["reverse_geocode"] = environment["geocode_status"]
                        if app_info.get("geocode_detail"):
                            environment["capture_errors"]["reverse_geocode_detail"] = str(
                                app_info["geocode_detail"]
                            )[:300]
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


def capture_failure(driver, directory: Path, remote_url: str | None = None) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    artifacts = {}
    try:
        path = directory / "failure.png"
        if driver.save_screenshot(str(path)):
            artifacts["screenshot"] = str(path)
    except Exception as error:
        artifacts["screenshot_error"] = type(error).__name__
    try:
        path = directory / "page.xml"
        path.write_text(redact_url(driver.page_source, remote_url), encoding="utf-8")
        artifacts["page_source"] = str(path)
    except Exception as error:
        artifacts["page_source_error"] = type(error).__name__
    print("TEST_DIAGNOSTICS=" + json.dumps(artifacts, ensure_ascii=False), flush=True)
    return artifacts


def write_report(report: dict, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    json_path = directory / "report.json"
    markdown_path = directory / "report.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    environment = report.get("environment") or {}
    counts = report.get("result_counts") or {}
    quality = report.get("quality_metrics") or {}
    lines = [
        "# Flutter 在线收听测试报告",
        "",
        f"- 结果：{'通过' if report['status'] == 'passed' else '失败'}",
        f"- 平台：`{report['platform']}`",
        f"- 执行环境：`{report.get('execution_backend', 'sauce')}`",
        f"- Appium 会话：`{report.get('session_id') or '未创建'}`",
        f"- Sauce 数据中心：`{report['sauce_data_center'] or '不适用'}`",
        f"- 目标地区设置：`{json.dumps(report.get('region_target'), ensure_ascii=False)}`",
        f"- 设备：`{environment.get('device_name') or '未知'}`",
        f"- 系统语言：`{environment.get('device_locale') or environment.get('device_language') or '未知'}`",
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
        f"- App 定位来源：`{environment.get('app_location_source') or '未取得'}`",
        f"- App 定位年龄：`{environment.get('app_location_age_ms') if environment.get('app_location_age_ms') is not None else '未取得'}` 毫秒",
        f"- App 定位授权：`{environment.get('app_location_permission') or '未取得'}`",
        f"- App 定位精度状态：`{environment.get('app_precision_status') or '未取得'}`",
        f"- App 可用定位来源：`{environment.get('app_location_providers') or '未取得'}`",
        f"- App 与 Appium 坐标距离：`{environment.get('gps_consistency_distance_km') if environment.get('gps_consistency_distance_km') is not None else '未取得'}` 公里",
        "- App 翻译方向：`en-US → zh-CN`",
        f"- 音频来源：`{report.get('audio_source')}`",
        f"- 仅验证下载：`{report.get('download_only')}`",
        f"- 要求翻译评分成功：`{report.get('require_llm_score', True)}`",
        f"- 开始：`{report['started_at']}`",
        f"- 结束：`{report['finished_at']}`",
        f"- 耗时：`{report['duration_seconds']}` 秒",
        f"- ASR 条数：`{counts.get('asr', '未取得')}`",
        f"- 翻译条数：`{counts.get('translation', '未取得')}`",
        "",
        "## App 自行下载 PCM",
        "",
        f"- 本机 URL 预检：`{json.dumps(report.get('url_preflight'), ensure_ascii=False)}`",
        f"- URL 输入方式：`{report.get('download_input_method') or '未输入'}`",
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
    if failure := report.get("failure"):
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
    if report["diagnostics"]:
        lines.extend(["", "## 诊断文件", ""])
        lines.extend(f"- {name}：`{path}`" for name, path in report["diagnostics"].items())
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        "TEST_REPORT=" + json.dumps({"json": str(json_path), "markdown": str(markdown_path)}, ensure_ascii=False),
        flush=True,
    )


def main() -> int:
    started = time.monotonic()
    run_id = f"setup-{uuid.uuid4()}"
    platform = test_platform()
    backend = test_backend()
    region = os.environ.get("SAUCE_REGION", "us-west-1").strip()
    download_only = os.environ.get("SAUCE_DOWNLOAD_ONLY", "0").strip() == "1"
    require_llm_score = os.environ.get("TEST_REQUIRE_LLM", "1").strip() != "0"
    print("TEST_MODE=" + ("download_only" if download_only else "full_online_listen"), flush=True)
    remote_url = None
    report = {
        "test": "Flutter online listen / app HTTPS PCM download",
        "platform": platform,
        "execution_backend": backend,
        "status": "failed",
        "session_id": None,
        "sauce_data_center": region if backend == "sauce" else None,
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
        "require_llm_score": require_llm_score,
        "url_preflight": None,
        "download": None,
        "failure": None,
        "diagnostics": {},
    }
    driver = None
    passed = False
    step = "创建 Appium 会话"

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
            if os.environ.get("SAUCE_SKIP_URL_PREFLIGHT", "0").strip() != "1":
                start_step("本机预检远程 PCM")
                report["url_preflight"] = preflight_url(remote_url)
                print("TEST_URL_PREFLIGHT=" + json.dumps(report["url_preflight"]), flush=True)
        start_step("创建 Appium 会话")
        validate_session_setup(platform, region, backend)
        region_target = requested_region_settings()
        report["region_target"] = region_target
        driver = create_test_driver(platform, region, backend, region_target, report["test"])
        run_id = driver.session_id or run_id
        report["session_id"] = driver.session_id
        start_step("核对安装包类型")
        if platform == "Android" and "tmk.sauce.home.start" not in driver.page_source \
                and "开始在线翻译" in driver.page_source:
            raise RuntimeError(
                "安装包指向原生 Android Sample；请改用 "
                "Android/saucelabs/test_online_listen.py，"
                "或使用 Flutter Android APK"
            )
        start_step("读取设备环境")
        report["environment"] = (
            {
                "platform": platform,
                "execution_backend": backend,
                "sauce_data_center": region if backend == "sauce" else None,
                "session_id": driver.session_id,
                "device_name": driver.capabilities.get("deviceName")
                    or driver.capabilities.get("appium:deviceName"),
                "capture_errors": {},
            }
            if download_only else device_environment(driver, platform, region, backend)
        )
        report["environment"]["region_target"] = region_target
        if not download_only and region_target["gps"] and report["environment"]["gps"]:
            report["environment"]["gps_target_distance_km"] = round(
                gps_distance_km(region_target["gps"], report["environment"]["gps"]), 2
            )
        print("TEST_ENVIRONMENT=" + json.dumps(report["environment"], ensure_ascii=False), flush=True)
        if not download_only and any(region_target.values()):
            start_step("校验目标地区信号")
            measured = report["environment"]
            if region_target["gps"]:
                if measured["gps_source"] not in {"app_core_location", "app_android_location"}:
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

        start_step("等待首页语言加载并滚动到语言设置")
        WebDriverWait(driver, 90).until(
            lambda current: any(
                item.is_enabled()
                for item in control_elements(current, "tmk.sauce.home.start", "开始翻译", platform)
            )
        )
        scroll_home_to_languages(driver, platform)
        start_step("切换为英语→中文")
        click_control(driver, "tmk.sauce.home.swap", "⇄", platform)
        start_step("进入在线收听")
        click_control(driver, "tmk.sauce.home.start", "开始翻译", platform)
        WebDriverWait(driver, 30).until(lambda current: visible_text_elements(current, "在线收听"))
        start_step("选择测试音频")
        click_control(driver, "tmk.sauce.listen.testAudio", "测试音频", platform)
        WebDriverWait(driver, 30).until(lambda current: result_counts(current, platform) is not None)
        if remote_url:
            start_step("将 HTTPS URL 输入 App")
            report["download_input_method"] = enter_remote_url(driver, remote_url, platform)
            start_step("让 App 从 HTTPS 下载 PCM")
            button = download_button(driver, platform)
            if not button or not button.is_enabled():
                raise RuntimeError("App 下载按钮在点击前已禁用，HTTPS URL 可能丢失")
            button.click()
            start_step("校验 App 下载的字节数和 SHA-256")
            report["download"] = wait_and_verify(driver, report)
            if download_only:
                start_step("仅下载验证完成，跳过开始收听和质量测试")
                passed = True
                report["status"] = "passed"
                return 0
        start_step("开始收听")
        click_control(driver, "tmk.sauce.listen.start", "开始收听", platform, timeout=120)
        start_step("等待测试音频推送完毕")
        WebDriverWait(driver, 75).until(
            lambda current: control_elements(
                current, "tmk.sauce.listen.audioComplete", "测试音频已推送完毕", platform
            )
        )
        start_step("等待识别和翻译结果")
        counts = WebDriverWait(driver, 90).until(lambda current: received_results(current, platform))
        report["result_counts"] = {"asr": counts[0], "translation": counts[1]}
        print(f"Received online listening results: ASR={counts[0]}, translation={counts[1]}", flush=True)
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
        if require_llm_score and report["quality_metrics"]["translation"]["match"]["status"] != "scored":
            raise RuntimeError("Translation quality scoring unavailable: " +
                               report["quality_metrics"]["translation"]["match"].get("reason", "unknown"))
        passed = True
        report["status"] = "passed"
        return 0
    except Exception as error:
        if driver is not None:
            report["diagnostics"] = capture_failure(driver, output_directory(run_id), remote_url)
        detail = redact_url(str(error).strip(), remote_url)
        for secret in (os.environ.get("SAUCE_ACCESS_KEY"), os.environ.get("SAUCE_USERNAME")):
            if secret:
                detail = detail.replace(secret, "[REDACTED]")
        report["failure"] = {"step": step, "type": type(error).__name__, "message": detail[:4000]}
        raise RuntimeError(
            f"{step} failed ({type(error).__name__})" + (f": {detail}" if detail else "")
        ) from error
    finally:
        if driver is not None and backend == "sauce":
            try:
                driver.execute_script(f"sauce:job-result={'passed' if passed else 'failed'}")
            except Exception as error:
                report["sauce_job_result_error"] = type(error).__name__
                print(f"Could not report Sauce job result: {type(error).__name__}", file=sys.stderr)
        if driver is not None:
            try:
                driver.quit()
            except Exception as error:
                report["session_close_error"] = type(error).__name__
                print(f"Could not close Appium session: {type(error).__name__}", file=sys.stderr)
        report["finished_at"] = utc_now()
        report["duration_seconds"] = round(time.monotonic() - started, 2)
        write_report(report, output_directory(run_id))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Flutter online listening smoke test failed: {error}", file=sys.stderr)
        sys.exit(1)
