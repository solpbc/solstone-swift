#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCAN_CMD=(rg -n -i --pcre2 '\b(capture|record|recording|keeper|assistant)\b' Sources Tests UITests SolstoneLiveActivityWidget SolstoneNotificationContent)
RAW_MATCHES="$("${SCAN_CMD[@]}" || true)"

WHITELIST_REGEX='AVAudioSession\.Category\.record|\.playAndRecord|requestRecordPermission|recordPermission|record permission|AVCaptureMetadataOutput|UNUserNotificationCenter|ObserverRecorder|ObserverRecording|LiveObserverRecorder|ObserverRecordedChunk|IntegrationTestObserverRecorder|recordKeepaliveFailure|recordingID|Tests/Mocks/'

FILTERED="$(printf '%s\n' "$RAW_MATCHES" | grep -Evi "$WHITELIST_REGEX" || true)"

if [[ -n "$FILTERED" ]]; then
  echo "terminology assertion failed:"
  printf '%s\n' "$FILTERED"
  exit 1
fi

echo "terminology assertion passed"
