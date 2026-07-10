#!/usr/bin/env bash

set -euo pipefail

TITLE=""
STATUS=""
MENTIONS_ON_SUCCESS=""
MENTIONS_ON_FAILURE=""
NOTIFY_RESULT="unknown"
NOTIFY_REASON=""
HAS_CANCELLED_RESULT="false"
declare -a RESULTS=()
declare -a LINES=()

usage() {
  cat <<'EOF'
Usage:
  notify_workflow_feishu.sh --title <title> [options]

Options:
  --title <text>                 Notification title.
  --status <success|failure>     Explicit status. If omitted, status is inferred from --result values.
  --result <status>              A job result used for status inference; repeatable.
  --mentions-on-success <list>   Mentions for success (comma separated, e.g. "userA,userB,@all").
  --mentions-on-failure <list>   Mentions for failure (comma separated).
  --line <text>                  Message line; repeatable.

Environment:
  FEISHU_WEBHOOK_URL, FEISHU_WEBHOOK_SECRET, FEISHU_USERIDS_MAP are read by notify_feishu.py.
  FEISHU_SUCCESS_NOTIFY_USERS / FEISHU_FAILED_NOTIFY_USERS can provide default mention lists.
  FEISHU_SUCCESS_NOTIFY_IOS_USERS / FEISHU_FAILED_NOTIFY_IOS_USERS are kept for compatibility.
EOF
}

set_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

append_summary() {
  local line="$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$line" >> "$GITHUB_STEP_SUMMARY"
  fi
}

emit_result() {
  local title="$1"
  local status="$2"
  local mentions="$3"
  local result="$4"
  local reason="$5"

  set_output "feishu_notify_result" "$result"
  set_output "feishu_notify_status" "$status"
  set_output "feishu_notify_mentions" "$mentions"
  set_output "feishu_notify_reason" "$reason"

  echo "[notify_workflow_feishu] title=${title} status=${status} result=${result} mentions=${mentions:-<none>}"
  if [[ -n "$reason" ]]; then
    echo "[notify_workflow_feishu] reason=${reason}"
  fi

  append_summary "## Feishu Notification"
  append_summary "- title: ${title}"
  append_summary "- business status: ${status}"
  append_summary "- notify result: ${result}"
  if [[ -n "$mentions" ]]; then
    append_summary "- mentions: ${mentions}"
  else
    append_summary "- mentions: (none)"
  fi
  if [[ -n "$reason" ]]; then
    append_summary "- detail: ${reason}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --status)
      STATUS="${2:-}"
      shift 2
      ;;
    --result)
      RESULTS+=("${2:-}")
      shift 2
      ;;
    --mentions-on-success)
      MENTIONS_ON_SUCCESS="${2:-}"
      shift 2
      ;;
    --mentions-on-failure)
      MENTIONS_ON_FAILURE="${2:-}"
      shift 2
      ;;
    --line)
      LINES+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[notify_workflow_feishu] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TITLE" ]]; then
  echo "[notify_workflow_feishu] Missing required --title" >&2
  usage >&2
  exit 2
fi

if [[ -z "$STATUS" ]]; then
  STATUS="success"
  for result in "${RESULTS[@]}"; do
    if [[ "$result" == "cancelled" ]]; then
      HAS_CANCELLED_RESULT="true"
      continue
    fi
    if [[ "$result" != "success" ]]; then
      STATUS="failure"
      break
    fi
  done
  if [[ "$HAS_CANCELLED_RESULT" == "true" ]] && [[ "$STATUS" == "success" ]]; then
    STATUS="cancelled"
  fi
fi

if [[ -z "$MENTIONS_ON_SUCCESS" ]]; then
  MENTIONS_ON_SUCCESS="${FEISHU_SUCCESS_NOTIFY_USERS:-${FEISHU_SUCCESS_NOTIFY_ANDROID_USERS:-${FEISHU_SUCCESS_NOTIFY_IOS_USERS:-}}}"
fi
if [[ -z "$MENTIONS_ON_FAILURE" ]]; then
  MENTIONS_ON_FAILURE="${FEISHU_FAILED_NOTIFY_USERS:-${FEISHU_FAILED_NOTIFY_ANDROID_USERS:-${FEISHU_FAILED_NOTIFY_IOS_USERS:-}}}"
fi

# Debug: print mentions resolution
echo "[notify_workflow_feishu] FEISHU_SUCCESS_NOTIFY_USERS=$([[ -n "${FEISHU_SUCCESS_NOTIFY_USERS:-}" ]] && echo true || echo false)"
echo "[notify_workflow_feishu] FEISHU_SUCCESS_NOTIFY_ANDROID_USERS=$([[ -n "${FEISHU_SUCCESS_NOTIFY_ANDROID_USERS:-}" ]] && echo true || echo false)"
echo "[notify_workflow_feishu] FEISHU_SUCCESS_NOTIFY_IOS_USERS=$([[ -n "${FEISHU_SUCCESS_NOTIFY_IOS_USERS:-}" ]] && echo true || echo false)"
echo "[notify_workflow_feishu] MENTIONS_ON_SUCCESS=${MENTIONS_ON_SUCCESS:-<empty>}"
echo "[notify_workflow_feishu] MENTIONS_ON_FAILURE=${MENTIONS_ON_FAILURE:-<empty>}"

TARGET_MENTIONS="$MENTIONS_ON_SUCCESS"
if [[ "$STATUS" != "success" ]]; then
  TARGET_MENTIONS="$MENTIONS_ON_FAILURE"
fi

MESSAGE=""
for line in "${LINES[@]}"; do
  if [[ -n "$line" ]]; then
    if [[ -z "$MESSAGE" ]]; then
      MESSAGE="$line"
    else
      MESSAGE+=$'\n'"$line"
    fi
  fi
done

URL="${FEISHU_WEBHOOK_URL:-}"
SECRET="${FEISHU_WEBHOOK_SECRET:-}"
USERIDS_MAP="${FEISHU_USERIDS_MAP:-}"
URL_VALID="false"
if [[ "$URL" == https://* ]] || [[ "$URL" == IM_WEBHOOK=https://* ]] || [[ "$URL" == FEISHU_WEBHOOK_URL=https://* ]]; then
  URL_VALID="true"
fi

echo "[notify_workflow_feishu] FEISHU_WEBHOOK_URL_SET=$([[ -n "$URL" ]] && echo true || echo false)"
echo "[notify_workflow_feishu] FEISHU_WEBHOOK_URL_LOOKS_VALID=${URL_VALID}"
echo "[notify_workflow_feishu] FEISHU_WEBHOOK_SECRET_SET=$([[ -n "$SECRET" ]] && echo true || echo false)"
echo "[notify_workflow_feishu] FEISHU_WEBHOOK_SECRET_LENGTH=${#SECRET}"
echo "[notify_workflow_feishu] FEISHU_USERIDS_MAP_SET=$([[ -n "$USERIDS_MAP" ]] && echo true || echo false)"

if [[ "$HAS_CANCELLED_RESULT" == "true" ]]; then
  NOTIFY_RESULT="skipped"
  NOTIFY_REASON="job/workflow cancelled"
  emit_result "$TITLE" "$STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"
  exit 0
fi

if [[ -z "$URL" ]]; then
  NOTIFY_RESULT="skipped"
  NOTIFY_REASON="FEISHU_WEBHOOK_URL is empty"
  emit_result "$TITLE" "$STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"
  exit 0
fi

if [[ "$URL_VALID" != "true" ]]; then
  NOTIFY_RESULT="skipped"
  NOTIFY_REASON="FEISHU_WEBHOOK_URL format invalid"
  emit_result "$TITLE" "$STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"
  exit 0
fi

set +e
SEND_OUTPUT="$(python3 .github/scripts/notify_feishu.py \
  --title "$TITLE" \
  --status "$STATUS" \
  --message "$MESSAGE" \
  --mentions "$TARGET_MENTIONS" 2>&1)"
SEND_EXIT=$?
set -e

if [[ $SEND_EXIT -eq 0 ]]; then
  NOTIFY_RESULT="success"
  NOTIFY_REASON=""
else
  NOTIFY_RESULT="failed"
  NOTIFY_REASON="$(printf '%s' "$SEND_OUTPUT" | tail -n 1 | tr '\n' ' ')"
fi

echo "$SEND_OUTPUT"
emit_result "$TITLE" "$STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"
exit 0
