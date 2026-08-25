#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCAN_ROOTS=(
  Sources
  Watch
  SolstoneWatchComplication
  SolstoneBroadcastExtension
  SolstoneLiveActivityWidget
  SolstoneNotificationContent
  SolstoneShareExtension
)

matches=""
scan_status=0
matches="$(grep -rn "dev-copy:" "${SCAN_ROOTS[@]}")" || scan_status=$?

case "$scan_status" in
  0)
    echo "dev-copy assertion failed:"
    printf '%s\n' "$matches"
    exit 1
    ;;
  1)
    echo "dev-copy assertion passed"
    ;;
  *)
    echo "dev-copy assertion failed: could not measure: grep exited $scan_status" >&2
    exit "$scan_status"
    ;;
esac
