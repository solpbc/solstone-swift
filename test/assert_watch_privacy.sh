#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT_DIR"

manifest="Watch/PrivacyInfo.xcprivacy"

extract_value() {
  local key="$1"
  local format="$2"
  if ! plutil -extract "$key" "$format" -o - "$manifest" 2>/dev/null; then
    echo "watch privacy assertion failed: ${key} missing from ${manifest}" >&2
    exit 1
  fi
}

tracking_json="$(extract_value NSPrivacyTracking raw)"
tracking_domains_json="$(extract_value NSPrivacyTrackingDomains json)"
collected_data_json="$(extract_value NSPrivacyCollectedDataTypes json)"
accessed_api_json="$(extract_value NSPrivacyAccessedAPITypes json)"

if ! TRACKING_JSON="$tracking_json" \
    TRACKING_DOMAINS_JSON="$tracking_domains_json" \
    COLLECTED_DATA_JSON="$collected_data_json" \
    ACCESSED_API_JSON="$accessed_api_json" \
    python3 -c '
import json
import os
import sys

checks = [
    ("NSPrivacyTracking", json.loads(os.environ["TRACKING_JSON"]), False),
    ("NSPrivacyTrackingDomains", json.loads(os.environ["TRACKING_DOMAINS_JSON"]), []),
    ("NSPrivacyCollectedDataTypes", json.loads(os.environ["COLLECTED_DATA_JSON"]), []),
    ("NSPrivacyAccessedAPITypes", json.loads(os.environ["ACCESSED_API_JSON"]), []),
]

for key, actual, expected in checks:
    if actual != expected:
        print(f"{key}: expected {expected!r}, got {actual!r}", file=sys.stderr)
        sys.exit(1)
'; then
  echo "watch privacy assertion failed: manifest values are not exact"
  exit 1
fi

if rg -n "showsBackgroundLocationIndicator" Watch/Sources/LiveWatchAudioRecorder.swift Watch/Sources/LiveWatchLocationProvider.swift; then
  echo "watch privacy assertion failed: indicator-suppression flag found"
  exit 1
fi

if ! rg -q "allowsBackgroundLocationUpdates = true" Watch/Sources/LiveWatchLocationProvider.swift; then
  echo "watch privacy assertion failed: background location start flag missing"
  exit 1
fi

if ! rg -q "allowsBackgroundLocationUpdates = false" Watch/Sources/LiveWatchLocationProvider.swift; then
  echo "watch privacy assertion failed: background location stop reset missing"
  exit 1
fi

echo "watch privacy assertion passed"
