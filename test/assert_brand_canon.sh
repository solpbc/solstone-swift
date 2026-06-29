#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FORBIDDEN_REGEX='\b(sign in|signed in|signing in|sign-in|signin|log in|logged in|logging in|login|your account|account settings|my account|linked|authenticate|authentication|authenticating|passkey|email|password|create account|sign up|signup)\b'
SCAN_CMD=(rg -n -i --pcre2 "$FORBIDDEN_REGEX" Sources Tests UITests SolstoneLiveActivityWidget SolstoneNotificationContent)
RAW_MATCHES="$("${SCAN_CMD[@]}" || true)"

# Existing network captive-portal copy and required mismatch support contact, not app-owned account surfaces.
WHITELIST_REGEX='(Sources/ContentView\.swift:.*your WiFi network may require sign-in|Sources/SourceVocabulary\.swift:.*journalMarkMismatchEmailSupport.*email support@solstone\.app)'

FILTERED="$(printf '%s\n' "$RAW_MATCHES" | grep -Evi "$WHITELIST_REGEX" || true)"

if [[ -n "$FILTERED" ]]; then
  echo "brand canon assertion failed:"
  printf '%s\n' "$FILTERED"
  exit 1
fi

if ! rg -q -i --pcre2 "$FORBIDDEN_REGEX" test/fixtures/brand_canon_negative.swift.txt; then
  echo "brand canon assertion failed: negative fixture did not trip regex"
  exit 1
fi

echo "brand canon assertion passed"
