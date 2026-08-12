#!/usr/bin/env bash

set -euo pipefail

TITLE=""
VERSION=""
BUILD_NUMBER=""
BRANCH=""
ANDROID_RESULT=""
IOS_RESULT=""
ANDROID_DOWNLOAD_URL=""
IOS_DOWNLOAD_URL=""
RELEASE_URL=""
RELEASE_TAG=""
MENTIONS_ON_SUCCESS=""
MENTIONS_ON_FAILURE=""
NOTIFY_RESULT="unknown"
NOTIFY_REASON=""
HAS_CANCELLED_RESULT="false"
HAS_SKIPPED_RESULT="false"
OVERALL_STATUS="success"

usage() {
  cat <<'EOF'
Usage:
  notify_workflow_feishu.sh --title <title> [options]

Options:
  --title <text>                 Notification title
  --version <version>            Version number (vX.Y.Z)
  --build-number <number>        Build number
  --branch <branch>              Git branch name
  --android-result <status>      Android build result (success/failure/skipped/cancelled)
  --ios-result <status>          iOS build result (success/failure/skipped/cancelled)
  --android-download-url <url>   Android download URL
  --ios-download-url <url>       iOS download URL
  --release-url <url>            GitHub Release URL
  --release-tag <tag>            Release tag (for fetching notes)
  --mentions-on-success <list>   Mentions for success (comma separated)
  --mentions-on-failure <list>   Mentions for failure (comma separated)

Environment:
  FEISHU_WEBHOOK_URL, FEISHU_WEBHOOK_SECRET, FEISHU_USERIDS_MAP are read by notify_feishu.py.
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
    --title) TITLE="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --android-result) ANDROID_RESULT="${2:-}"; shift 2 ;;
    --ios-result) IOS_RESULT="${2:-}"; shift 2 ;;
    --android-download-url) ANDROID_DOWNLOAD_URL="${2:-}"; shift 2 ;;
    --ios-download-url) IOS_DOWNLOAD_URL="${2:-}"; shift 2 ;;
    --release-url) RELEASE_URL="${2:-}"; shift 2 ;;
    --release-tag) RELEASE_TAG="${2:-}"; shift 2 ;;
    --mentions-on-success) MENTIONS_ON_SUCCESS="${2:-}"; shift 2 ;;
    --mentions-on-failure) MENTIONS_ON_FAILURE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[notify_workflow_feishu] Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$TITLE" ]]; then
  echo "[notify_workflow_feishu] Missing required --title" >&2
  exit 2
fi

# Analyze job results: detect cancelled and skipped
if [[ "$ANDROID_RESULT" == "cancelled" ]] || [[ "$IOS_RESULT" == "cancelled" ]]; then
  HAS_CANCELLED_RESULT="true"
fi

if [[ "$ANDROID_RESULT" == "skipped" ]] || [[ "$IOS_RESULT" == "skipped" ]]; then
  HAS_SKIPPED_RESULT="true"
fi

# Determine overall status: only success/failure/cancelled
OVERALL_STATUS="success"
if [[ "$HAS_CANCELLED_RESULT" == "true" ]]; then
  OVERALL_STATUS="cancelled"
elif [[ "$ANDROID_RESULT" != "success" && "$ANDROID_RESULT" != "skipped" ]] || [[ "$IOS_RESULT" != "success" && "$IOS_RESULT" != "skipped" ]]; then
  OVERALL_STATUS="failure"
fi

echo "[notify_workflow_feishu] Job results - Android: $ANDROID_RESULT, iOS: $IOS_RESULT"
echo "[notify_workflow_feishu] Detected status: OVERALL_STATUS=$OVERALL_STATUS, HAS_CANCELLED_RESULT=$HAS_CANCELLED_RESULT, HAS_SKIPPED_RESULT=$HAS_SKIPPED_RESULT"

# Choose mentions based on status
TARGET_MENTIONS="$MENTIONS_ON_SUCCESS"
if [[ "$OVERALL_STATUS" != "success" ]]; then
  TARGET_MENTIONS="$MENTIONS_ON_FAILURE"
fi

# Fallback to environment variables
if [[ -z "$TARGET_MENTIONS" ]]; then
  if [[ "$OVERALL_STATUS" == "success" ]]; then
    TARGET_MENTIONS="${FEISHU_SUCCESS_NOTIFY_USERS:-${FEISHU_SUCCESS_NOTIFY_ANDROID_USERS:-${FEISHU_SUCCESS_NOTIFY_IOS_USERS:-}}}"
  else
    TARGET_MENTIONS="${FEISHU_FAILED_NOTIFY_USERS:-${FEISHU_FAILED_NOTIFY_ANDROID_USERS:-${FEISHU_FAILED_NOTIFY_IOS_USERS:-}}}"
  fi
fi

echo "[notify_workflow_feishu] Target mentions: ${TARGET_MENTIONS:-<none>}"

# Handle cancelled status
if [[ "$HAS_CANCELLED_RESULT" == "true" ]]; then
  NOTIFY_RESULT="skipped"
  NOTIFY_REASON="Job cancelled"
  emit_result "$TITLE" "$OVERALL_STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"
  exit 0
fi

# Fetch Release Notes from GitHub Release
RELEASE_NOTES=""
RELEASE_NOTES_RAW=""
if [[ -n "$RELEASE_TAG" ]]; then
  echo "[notify_workflow_feishu] Fetching release notes for tag: $RELEASE_TAG"
  RELEASE_NOTES_RAW=$(gh release view "$RELEASE_TAG" --json body --jq '.body' 2>/dev/null || echo "")
  if [[ -z "$RELEASE_NOTES_RAW" ]]; then
    echo "[notify_workflow_feishu] Could not fetch release notes, will only show Release link"
  else
    echo "[notify_workflow_feishu] Release notes fetched successfully (${#RELEASE_NOTES_RAW} chars)"
    # Limit to first 5 lines
    RELEASE_NOTES=$(echo "$RELEASE_NOTES_RAW" | head -n 5)
    line_count=$(echo "$RELEASE_NOTES_RAW" | wc -l)
    if [[ $line_count -gt 5 ]]; then
      echo "[notify_workflow_feishu] Release notes truncated: $line_count lines → 5 lines (users can see full notes via Release URL)"
    fi
  fi
fi

# Convert result to emoji status
android_status="❌ Failed"
if [[ "$ANDROID_RESULT" == "success" ]]; then
  android_status="✅ Success"
elif [[ "$ANDROID_RESULT" == "skipped" ]]; then
  android_status="⊘ Skipped"
elif [[ "$ANDROID_RESULT" == "cancelled" ]]; then
  android_status="◼ Cancelled"
fi

ios_status="❌ Failed"
if [[ "$IOS_RESULT" == "success" ]]; then
  ios_status="✅ Success"
elif [[ "$IOS_RESULT" == "skipped" ]]; then
  ios_status="⊘ Skipped"
elif [[ "$IOS_RESULT" == "cancelled" ]]; then
  ios_status="◼ Cancelled"
fi

# Build message content
MESSAGE=""

if [[ -n "$VERSION" ]]; then
  MESSAGE+="Version: $VERSION"
  MESSAGE+=$'\n'
  MESSAGE+=$'\n'
fi



MESSAGE+="Build Status"
MESSAGE+=$'\n'
MESSAGE+="- Android: $android_status"
MESSAGE+=$'\n'
MESSAGE+="- iOS: $ios_status"
MESSAGE+=$'\n'
MESSAGE+=$'\n'

MESSAGE+="Download"
MESSAGE+=$'\n'

if [[ -z "$ANDROID_DOWNLOAD_URL" ]]; then
  MESSAGE+="- Android（蒲公英）: Coming Soon"
else
  MESSAGE+="- Android（蒲公英）: $ANDROID_DOWNLOAD_URL"
fi

MESSAGE+=$'\n'

if [[ -z "$IOS_DOWNLOAD_URL" ]]; then
  MESSAGE+="- iOS（蒲公英）: Coming Soon"
else
  MESSAGE+="- iOS（蒲公英）: $IOS_DOWNLOAD_URL"
fi

MESSAGE+=$'\n'
MESSAGE+=$'\n'

MESSAGE+="GitHub Release"
MESSAGE+=$'\n'
MESSAGE+="$RELEASE_URL"
MESSAGE+=$'\n'

if [[ -n "$RELEASE_NOTES" ]]; then
  MESSAGE+=$'\n'
  MESSAGE+="Release Notes (first 5 lines)"
  MESSAGE+=$'\n'
  MESSAGE+="$RELEASE_NOTES"
  MESSAGE+=$'\n'
  MESSAGE+=$'\n'
  MESSAGE+="👉 See full release notes at GitHub Release link above"
fi

# Validate webhook URL
URL="${FEISHU_WEBHOOK_URL:-}"
SECRET="${FEISHU_WEBHOOK_SECRET:-}"
USERIDS_MAP="${FEISHU_USERIDS_MAP:-}"

echo "[notify_workflow_feishu] FEISHU_WEBHOOK_URL_SET=$([[ -n "$URL" ]] && echo true || echo false)"
echo "[notify_workflow_feishu] FEISHU_WEBHOOK_URL_LENGTH=${#URL}"
echo "[notify_workflow_feishu] FEISHU_WEBHOOK_SECRET_SET=$([[ -n "$SECRET" ]] && echo true || echo false)"
echo "[notify_workflow_feishu] FEISHU_WEBHOOK_SECRET_LENGTH=${#SECRET}"
echo "[notify_workflow_feishu] FEISHU_USERIDS_MAP_SET=$([[ -n "$USERIDS_MAP" ]] && echo true || echo false)"

# Webhook URL format validation
URL_VALID="false"
if [[ "$URL" == https://* ]] || [[ "$URL" == IM_WEBHOOK=https://* ]] || [[ "$URL" == FEISHU_WEBHOOK_URL=https://* ]]; then
  URL_VALID="true"
fi

echo "[notify_workflow_feishu] FEISHU_WEBHOOK_URL_LOOKS_VALID=${URL_VALID}"

if [[ -z "$URL" ]]; then
  NOTIFY_RESULT="skipped"
  NOTIFY_REASON="FEISHU_WEBHOOK_URL is empty"
  emit_result "$TITLE" "$OVERALL_STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"
  echo "[notify_workflow_feishu] Webhook URL is empty, skipping notification"
  exit 0
fi

if [[ "$URL_VALID" != "true" ]]; then
  NOTIFY_RESULT="skipped"
  NOTIFY_REASON="FEISHU_WEBHOOK_URL format invalid (expected https://...)"
  emit_result "$TITLE" "$OVERALL_STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"
  echo "[notify_workflow_feishu] Webhook URL format invalid, skipping notification"
  exit 0
fi

echo "[notify_workflow_feishu] Sending notification to Feishu"
echo "[notify_workflow_feishu] Title: $TITLE"
echo "[notify_workflow_feishu] Status: $OVERALL_STATUS"
echo "[notify_workflow_feishu] Mentions: ${TARGET_MENTIONS:-<none>}"

# Send notification - capture error but don't fail the workflow
set +e
SEND_OUTPUT="$(python3 .github/scripts/notify_feishu.py \
  --title "$TITLE" \
  --status "$OVERALL_STATUS" \
  --message "$MESSAGE" \
  --mentions "$TARGET_MENTIONS" 2>&1)"
SEND_EXIT=$?
set -e

if [[ $SEND_EXIT -eq 0 ]]; then
  NOTIFY_RESULT="success"
  NOTIFY_REASON=""
  echo "[notify_workflow_feishu] Notification sent successfully"
else
  NOTIFY_RESULT="failed"
  NOTIFY_REASON="$(printf '%s' "$SEND_OUTPUT" | tail -n 1 | tr '\n' ' ')"
  echo "[notify_workflow_feishu] ⚠️  Notification send failed (non-blocking): $NOTIFY_REASON"
  echo "[notify_workflow_feishu] Full output:"
  echo "$SEND_OUTPUT"
fi

echo "$SEND_OUTPUT"
emit_result "$TITLE" "$OVERALL_STATUS" "$TARGET_MENTIONS" "$NOTIFY_RESULT" "$NOTIFY_REASON"

# IMPORTANT: Always exit 0 - notification failure should not fail the workflow
echo "[notify_workflow_feishu] Workflow continues regardless of notification result"
exit 0
