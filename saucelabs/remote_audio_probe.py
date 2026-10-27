"""Shared checks for a PCM fetched by the app on a Sauce real device."""

from __future__ import annotations

import html
import hashlib
import json
import os
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

EXPECTED_BYTES = 679254
EXPECTED_SHA256 = "9167766ca3d9a18d2f5f9d24a4bbf225b952dddab946dfba88607f15c61dbcfc"
URL_PLACEHOLDER = "PASTE_HTTPS_PCM_URL_HERE"
DOWNLOAD_PREFIX = "TMK_TEST_DOWNLOAD="


def configured_url(script_placeholder: str, *, required: bool = False) -> str | None:
    """Environment overrides the script placeholder; validate before buying a session."""
    value = os.environ.get("SAUCE_TEST_PCM_URL", script_placeholder).strip()
    if not value or value == URL_PLACEHOLDER:
        if required:
            raise ValueError("Paste the HTTPS PCM URL into TEST_PCM_URL or set SAUCE_TEST_PCM_URL")
        return None
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("SAUCE_TEST_PCM_URL must be an HTTPS URL without embedded credentials")
    expires_at = signed_url_expires_at(value)
    if expires_at is not None and expires_at - time.time() < 300:
        raise ValueError(
            "PCM 签名 URL 已过期或剩余有效期不足 5 分钟；"
            "请重新生成有效期覆盖整个 Sauce 会话的 URL"
        )
    return value


def signed_url_expires_at(url: str) -> float | None:
    """Expiration for OSS V1/V2/V4 and S3-compatible V4 query signatures."""
    query = {
        name.lower(): values[-1]
        for name, values in parse_qs(urlsplit(url).query).items()
    }
    try:
        for date_key, duration_key in (
            ("x-oss-date", "x-oss-expires"),
            ("x-amz-date", "x-amz-expires"),
        ):
            if date_key in query and duration_key in query:
                start = datetime.strptime(query[date_key], "%Y%m%dT%H%M%SZ")
                return start.replace(tzinfo=timezone.utc).timestamp() + int(query[duration_key])
        for key in ("expires", "x-oss-expires"):
            if key in query:
                return float(query[key])
    except (ValueError, OverflowError):
        raise ValueError("PCM 签名 URL 的有效期参数无效，请重新生成 URL") from None
    return None


def _oss_error_code(body: bytes) -> str | None:
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        return None
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] == "Code":
            code = (element.text or "").strip()
            if re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", code):
                return code
    return None


def preflight_url(url: str, *, timeout: int = 20,
                  expected_bytes: int | None = EXPECTED_BYTES,
                  expected_sha256: str | None = EXPECTED_SHA256) -> dict:
    """Catch a stale or inaccessible PCM URL before creating a Sauce session.

    The device still performs its own GET and hash check during the test.
    Never include the signed URL in logs, reports, or raised errors.
    """
    request = Request(url, headers={"Accept": "application/octet-stream"})
    try:
        with urlopen(request, timeout=timeout) as response:
            status = response.status
            redirected = response.geturl() != url
            content = response.read((expected_bytes if expected_bytes is not None
                                     else 20 * 1024 * 1024) + 1)
    except HTTPError as error:
        code = _oss_error_code(error.read(8192))
        detail = f"，OSS Code={code}" if code else ""
        raise RuntimeError(
            f"本机预检 PCM URL 返回 HTTP {error.code}{detail}；"
            "请检查签名有效期和 OSS 访问规则后再占用 Sauce 真机"
        ) from None
    except URLError as error:
        raise RuntimeError(
            f"本机无法访问 PCM URL（{type(error.reason).__name__}）；"
            "如果只有 Sauce 真机能访问，可设置 SAUCE_SKIP_URL_PREFLIGHT=1"
        ) from None
    if redirected or status != 200:
        raise RuntimeError(f"本机预检 PCM URL 返回重定向或 HTTP {status}，App 要求直接返回 200")
    digest = hashlib.sha256(content).hexdigest()
    if len(content) == 0 or len(content) % 2 != 0 or len(content) > 20 * 1024 * 1024:
        raise RuntimeError(f"本机预检 PCM 长度无效：bytes={len(content)}")
    if ((expected_bytes is not None and len(content) != expected_bytes) or
            (expected_sha256 is not None and digest != expected_sha256)):
        raise RuntimeError(
            f"本机预检 PCM 不匹配：bytes={len(content)}，sha256={digest}；"
            "请确认 URL 指向预期语料"
        )
    return {"http_status": status, "bytes": len(content), "sha256": digest}


def parse_download(page_source: str) -> dict | None:
    root = ET.fromstring(page_source)
    for element in root.iter():
        for value in element.attrib.values():
            position = value.find(DOWNLOAD_PREFIX)
            if position < 0:
                continue
            try:
                payload, _ = json.JSONDecoder().raw_decode(value[position + len(DOWNLOAD_PREFIX):])
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and payload.get("status") in {
                "idle", "downloading", "ok", "failed"
            }:
                return payload
    return None


def wait_and_verify(driver, report: dict, timeout: int = 100,
                    startup_timeout: int = 10,
                    expected_bytes: int = EXPECTED_BYTES,
                    expected_sha256: str = EXPECTED_SHA256) -> dict:
    started = time.monotonic()
    deadline = started + timeout
    last_status = None
    while time.monotonic() < deadline:
        result = parse_download(driver.page_source)
        if result:
            report["download"] = result
            last_status = result["status"]
        if result and result["status"] in {"ok", "failed"}:
            print("TEST_DOWNLOAD=" + json.dumps(result, ensure_ascii=False), flush=True)
            if result["status"] != "ok":
                raise RuntimeError(f"App download failed: {result.get('error') or 'unknown'}; "
                                   f"HTTP={result.get('http_status')}")
            if result.get("http_status") != 200:
                raise RuntimeError(f"App reported unexpected HTTP status: {result.get('http_status')}")
            if result.get("bytes") != expected_bytes:
                raise RuntimeError(f"PCM size mismatch: {result.get('bytes')} != {expected_bytes}")
            if result.get("sha256") != expected_sha256:
                raise RuntimeError(f"PCM SHA-256 mismatch: {result.get('sha256')}")
            return result
        if last_status in {None, "idle"} and time.monotonic() - started >= startup_timeout:
            raise RuntimeError(
                f"App 下载未启动：状态={last_status or 'unavailable'}；"
                "请检查 URL 输入框和下载按钮"
            )
        time.sleep(1)
    raise TimeoutError(f"App 未在 {timeout} 秒内完成 PCM 下载；最后状态={last_status or 'unavailable'}")


def redact_url(value: str, url: str | None) -> str:
    if not url:
        return value
    return value.replace(url, "[REDACTED_URL]").replace(html.escape(url, quote=True), "[REDACTED_URL]")
