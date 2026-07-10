#!/usr/bin/env python3

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request


def normalize_secret(raw: str) -> str:
    value = (raw or "").strip().strip('"').strip("'")
    if "=" in value:
        key, remainder = value.split("=", 1)
        if key.strip().upper() in {"IM_SECRET", "FEISHU_WEBHOOK_SECRET"}:
            value = remainder.strip()
    return value


def normalize_webhook_url(raw: str) -> str:
    value = (raw or "").strip().strip('"').strip("'")
    if "=" in value:
        key, remainder = value.split("=", 1)
        if key.strip().upper() in {"IM_WEBHOOK", "FEISHU_WEBHOOK_URL"}:
            value = remainder.strip()
    return value


def parse_bool(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def split_user_ids(raw: str) -> list[str]:
    if not raw:
        return []
    values = []
    for part in raw.split(","):
        uid = part.strip()
        if uid:
            values.append(uid)
    return values


def parse_userids_map(raw: str) -> dict[str, str]:
    if not raw:
        return {}
    value = raw.strip().strip('"').strip("'")
    if "=" in value:
        key, remainder = value.split("=", 1)
        if key.strip().upper() in {"FEISHU_USERIDS_MAP", "USERIDS_MAP"}:
            value = remainder.strip()
    try:
        data = json.loads(value)
    except json.JSONDecodeError:
        return {}
    if not isinstance(data, dict):
        return {}

    result: dict[str, str] = {}
    for key, value in data.items():
        if key is None:
            continue
        normalized_key = str(key).strip().lstrip("@").lower()
        if not normalized_key:
            continue
        user_id = ""
        if isinstance(value, str):
            user_id = value.strip()
        elif isinstance(value, dict):
            for candidate in ("user_id", "open_id", "feishu_user_id"):
                candidate_value = value.get(candidate)
                if isinstance(candidate_value, str) and candidate_value.strip():
                    user_id = candidate_value.strip()
                    break
        if user_id:
            result[normalized_key] = user_id
    return result


def resolve_user_ids_from_map(userids_map_raw: str, github_users_raw: str) -> list[str]:
    if not github_users_raw:
        return []
    mapping = parse_userids_map(userids_map_raw)
    if not mapping:
        return []
    resolved = []
    for name in [part.strip() for part in github_users_raw.split(",") if part.strip()]:
        normalized = name.lstrip("@").lower()
        user_id = mapping.get(normalized)
        if user_id:
            resolved.append(user_id)
    return resolved


def split_mentions(raw: str) -> tuple[list[str], bool]:
    if not raw:
        return [], False
    github_users = []
    at_all = False
    for part in raw.split(","):
        value = part.strip()
        if not value:
            continue
        normalized = value.lstrip("@").lower()
        if normalized == "all":
            at_all = True
        else:
            github_users.append(value)
    return github_users, at_all


def build_payload(
    title: str,
    status: str,
    lines: list[str],
    at_user_ids: list[str],
    at_all: bool,
) -> dict:
    status_text = {
        "success": "成功",
        "failure": "失败",
        "warning": "警告",
    }.get(status.lower(), status)

    content = "\n".join(f"- {line}" for line in lines if line.strip())
    content_blocks = [[{"tag": "text", "text": content or "无附加信息"}]]

    mention_block = [{"tag": "at", "user_id": uid} for uid in at_user_ids]
    if at_all:
        mention_block.append({"tag": "at", "user_id": "all"})
    if mention_block:
        content_blocks.append(mention_block)

    return {
        "msg_type": "post",
        "content": {
            "post": {
                "zh_cn": {
                    "title": f"{title} - {status_text}",
                    "content": content_blocks,
                }
            }
        },
    }


def apply_signature(payload: dict, secret: str) -> dict:
    if not secret:
        return payload

    timestamp = str(int(time.time()))
    string_to_sign = f"{timestamp}\n{secret}"
    sign = base64.b64encode(
        hmac.new(string_to_sign.encode("utf-8"), digestmod=hashlib.sha256).digest()
    ).decode("utf-8")

    signed_payload = dict(payload)
    signed_payload["timestamp"] = timestamp
    signed_payload["sign"] = sign
    return signed_payload


def send(webhook_url: str, payload: dict) -> dict:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        webhook_url,
        data=body,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            response_body = response.read().decode("utf-8", errors="replace")
            if response.status >= 300:
                raise RuntimeError(f"飞书通知失败，HTTP {response.status}，响应：{response_body}")
    except urllib.error.HTTPError as exc:
        response_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"飞书通知失败，HTTP {exc.code}，响应：{response_body}") from exc

    try:
        response_json = json.loads(response_body) if response_body else {}
    except json.JSONDecodeError:
        response_json = {"raw": response_body}

    code = response_json.get("code")
    if code is None:
        code = response_json.get("StatusCode")
    if code not in (None, 0):
        message = response_json.get("msg") or response_json.get("StatusMessage") or "未知错误"
        raise RuntimeError(f"飞书通知失败，业务码={code}，响应：{message}")
    return response_json


def main() -> int:
    env_webhook_url = normalize_webhook_url(os.getenv("FEISHU_WEBHOOK_URL", ""))
    env_secret = normalize_secret(os.getenv("FEISHU_WEBHOOK_SECRET", ""))
    env_userids_map = os.getenv("FEISHU_USERIDS_MAP", "")

    parser = argparse.ArgumentParser(description="发送飞书 webhook 通知")
    parser.add_argument("--webhook-url", default=env_webhook_url)
    parser.add_argument("--secret", default=env_secret)
    parser.add_argument("--title", default="Workflow")
    parser.add_argument("--status", default="info")
    parser.add_argument("--message", default="")
    parser.add_argument("--line", action="append", default=[])
    parser.add_argument("--mentions", default="")
    parser.add_argument("--at-user-id", action="append", default=[])
    parser.add_argument("--at-user-ids", default="")
    parser.add_argument("--at-github-users", default="")
    parser.add_argument("--userids-map", default=env_userids_map)
    parser.add_argument("--at-all", nargs="?", const="true", default="false")
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--retry-delay", type=float, default=2.0)
    args = parser.parse_args()

    try:
        webhook_url = normalize_webhook_url(args.webhook_url)
        secret = normalize_secret(args.secret)
        if not webhook_url.startswith("https://"):
            raise RuntimeError("飞书 webhook URL 无效，请检查 FEISHU_WEBHOOK_URL 是否只保存 URL 本身")

        lines = list(args.line)
        if args.message:
            lines.extend(line.strip() for line in args.message.splitlines() if line.strip())

        mention_users, mention_all = split_mentions(args.mentions)
        github_users_raw = args.at_github_users
        if mention_users:
            github_users_raw = ",".join(mention_users)
        at_user_ids = [uid.strip() for uid in args.at_user_id if uid and uid.strip()]
        at_user_ids.extend(split_user_ids(args.at_user_ids))
        resolved_ids = resolve_user_ids_from_map(args.userids_map, github_users_raw)
        at_user_ids.extend(resolved_ids)
        at_user_ids = list(dict.fromkeys(at_user_ids))
        at_all = parse_bool(args.at_all) or mention_all

        # Debug: print resolved user IDs
        if github_users_raw:
            print(f"[notify_feishu] GitHub users: {github_users_raw}", file=sys.stderr)
            for user_id in resolved_ids:
                display_id = user_id[:5] + "..." if len(user_id) > 5 else user_id
                print(f"[notify_feishu] Resolved Feishu ID (first 5): {display_id}", file=sys.stderr)
        if at_user_ids:
            print(f"[notify_feishu] Final @user IDs count: {len(at_user_ids)}", file=sys.stderr)
            for uid in at_user_ids:
                display_id = uid[:5] + "..." if len(uid) > 5 else uid
                print(f"[notify_feishu]   - {display_id}", file=sys.stderr)
        if at_all:
            print(f"[notify_feishu] @all enabled", file=sys.stderr)

        payload = build_payload(args.title, args.status, lines, at_user_ids, at_all)
        payload = apply_signature(payload, secret)

        retries = max(args.retries, 1)
        last_exc: Exception | None = None
        response = None
        for attempt in range(1, retries + 1):
            try:
                response = send(webhook_url, payload)
                break
            except Exception as exc:  # noqa: BLE001
                last_exc = exc
                message = str(exc)
                non_retryable = (
                    "业务码=" in message
                    or "URL 无效" in message
                    or "HTTP 400" in message
                    or "HTTP 401" in message
                    or "HTTP 403" in message
                    or "HTTP 404" in message
                )
                if non_retryable or attempt >= retries:
                    raise
                print(
                    f"[notify_feishu] attempt {attempt}/{retries} failed, retrying in {args.retry_delay:.1f}s: {message}",
                    file=sys.stderr,
                )
                time.sleep(max(args.retry_delay, 0.0))

        if response is None and last_exc is not None:
            raise last_exc

        print(f"[notify_feishu] success response={json.dumps(response, ensure_ascii=False)}")
    except Exception as exc:  # noqa: BLE001
        print(f"[notify_feishu] {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
