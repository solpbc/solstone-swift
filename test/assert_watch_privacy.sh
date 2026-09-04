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

# NSPrivacyAccessedAPITypes is intentionally non-empty (CLO-reviewed, req_2vsv66ig,
# 2026-09-04): FileTimestamp/UserDefaults reads in WatchCaptureProtocols.swift,
# WatchCaptureStorageActor.swift, and WatchSourceFacts.swift. A change to this list
# needs the same review, not a silent edit to make the assertion pass.
checks = [
    ("NSPrivacyTracking", json.loads(os.environ["TRACKING_JSON"]), False),
    ("NSPrivacyTrackingDomains", json.loads(os.environ["TRACKING_DOMAINS_JSON"]), []),
    ("NSPrivacyCollectedDataTypes", json.loads(os.environ["COLLECTED_DATA_JSON"]), []),
    (
        "NSPrivacyAccessedAPITypes",
        json.loads(os.environ["ACCESSED_API_JSON"]),
        [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
            },
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            },
        ],
    ),
]

for key, actual, expected in checks:
    if actual != expected:
        print(f"{key}: expected {expected!r}, got {actual!r}", file=sys.stderr)
        sys.exit(1)
'; then
  echo "watch privacy assertion failed: manifest values are not exact"
  exit 1
fi

audio_adapter="Sources/WatchCapture/LiveWatchAudioRecorder.swift"
location_provider="Watch/Sources/LiveWatchLocationProvider.swift"

# Preflight every scanned input. A missing path must fail closed rather than
# read as "pattern absent" via ripgrep's exit 2.
for scanned in "$audio_adapter" "$location_provider"; do
  if [ ! -f "$scanned" ]; then
    echo "watch privacy assertion failed: scanned path missing: ${scanned}" >&2
    exit 1
  fi
done

# Only ripgrep exit 1 means "no match". Anything >=2 is an error and fails closed.
rg_absent() {
  local pattern="$1"; shift
  local status=0
  rg -q "$pattern" "$@" || status=$?
  case "$status" in
    0) return 1 ;;
    1) return 0 ;;
    *)
      echo "watch privacy assertion failed: rg error (exit ${status}) scanning $* for ${pattern}" >&2
      exit 1
      ;;
  esac
}

if ! rg_absent "showsBackgroundLocationIndicator" "$audio_adapter" "$location_provider"; then
  echo "watch privacy assertion failed: indicator-suppression flag found"
  exit 1
fi

if rg_absent "allowsBackgroundLocationUpdates = true" "$location_provider"; then
  echo "watch privacy assertion failed: background location start flag missing"
  exit 1
fi

if rg_absent "allowsBackgroundLocationUpdates = false" "$location_provider"; then
  echo "watch privacy assertion failed: background location stop reset missing"
  exit 1
fi

echo "watch privacy assertion passed"
