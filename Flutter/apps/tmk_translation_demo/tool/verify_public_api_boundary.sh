#!/usr/bin/env bash
set -euo pipefail

sample_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_roots=("$sample_root/lib" "$sample_root/test")

failures=0

if ! rg -q --glob '*.dart' \
  "package:tmk_translation_flutter/tmk_translation_flutter.dart" \
  "${source_roots[@]}"; then
  printf '%s\n' 'Sample has no public tmk_translation_flutter entrypoint import.' >&2
  failures=1
fi

if rg -n --glob '*.dart' \
  -e 'package:tmk_translation_platform_interface' \
  -e 'package:tmk_translation_flutter/(src|pigeon)' \
  -e 'import .*tmk_translation_api\.g\.dart' \
  -e '\bTmkTranslationFlutter\b' \
  "${source_roots[@]}"; then
  printf '%s\n' 'Sample imports an internal platform, Pigeon, or generated path.' >&2
  failures=1
fi

if rg -n --glob '*.dart' \
  -e 'MethodChannel[[:space:]]*\(' \
  -e 'EventChannel[[:space:]]*\(' \
  -e 'BasicMessageChannel[[:space:]]*\(' \
  "${source_roots[@]}"; then
  printf '%s\n' 'Sample reaches a channel directly.' >&2
  failures=1
fi

if rg -n --no-filename -e '/Users/' -e '/home/' \
  "$sample_root/pubspec.yaml" "$sample_root/pubspec.lock"; then
  printf '%s\n' 'Sample dependency metadata contains an absolute local path.' >&2
  failures=1
fi

if git -C "$sample_root" ls-files --error-unmatch pubspec_overrides.yaml >/dev/null 2>&1; then
  printf '%s\n' 'Development pubspec_overrides.yaml must not be tracked.' >&2
  failures=1
fi

if (( failures != 0 )); then
  exit 1
fi

printf '%s\n' 'Sample public API boundary: PASS'
