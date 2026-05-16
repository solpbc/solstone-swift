#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCAN_CMD=(rg -n -i --pcre2 '\b(capture|record|recording|keeper|assistant|server|service)\b' Sources Tests UITests SolstoneLiveActivityWidget SolstoneNotificationContent)
RAW_MATCHES="$("${SCAN_CMD[@]}" || true)"

# Existing observer/voice terminology exceptions.
# Keychain service identifiers and Security API fields.
# AppConfig/server helper identifiers that are boundary names, not copy.
# HomeAPIError cases.
# ServerURL/LIVE_SERVER plumbing.
# HTTP fixtures and source comments.
WHITELIST_REGEX='AVAudioSession\.Category\.record|\.playAndRecord|requestRecordPermission|recordPermission|record permission|AVCaptureMetadataOutput|UNUserNotificationCenter|ObserverRecorder|ObserverRecording|LiveObserverRecorder|ObserverRecordedChunk|IntegrationTestObserverRecorder|recordKeepaliveFailure|recordingID|Tests/Mocks/|kSecAttrService|static let service|service: prodService|service: service|service: String|baseQuery\(service:|serverVersion|serverHost|private var server: String|LabeledContent\("journal", value: self\.server\)|HomeAPIError\.server|case server\(|case \.server\(|LIVE_SERVER|let server = processInfo|normalize\(server:|URL\(string: server\)|components\.host = server|"service unavailable"|// .*server'

FILTERED="$(printf '%s\n' "$RAW_MATCHES" | grep -Evi "$WHITELIST_REGEX" || true)"

if [[ -n "$FILTERED" ]]; then
  echo "terminology assertion failed:"
  printf '%s\n' "$FILTERED"
  exit 1
fi

echo "terminology assertion passed"
