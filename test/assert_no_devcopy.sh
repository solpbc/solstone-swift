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

# ⚠ The pattern is the whole gate, and it was wrong for the life of this script.
#
# It matched only `dev-copy:`, a marker convention nothing in this repo actually uses. The
# placeholder convention people reach for is `tbd`, so the gate ran green over 25 of them
# across the Live Activity, Control Center, Siri and widget surfaces — and `tbd: activity
# ended` reached an owner's Lock Screen on 2026-09-01 with a green gate behind it.
#
# A detector keyed to a string the codebase never emits cannot fail, and a gate that cannot
# fail reads exactly like a gate that passes. Match both markers, whole-word and
# case-insensitively, so `"tbd"`, `"tbd: …"` and `// tbd: …` all trip it. A placeholder in a
# comment counts: it marks unfinished work, and shipping it silently is the failure here.
PLACEHOLDER_PATTERN='(dev-copy:|\btbd\b)'

matches=""
scan_status=0
matches="$(grep -rniE "$PLACEHOLDER_PATTERN" "${SCAN_ROOTS[@]}")" || scan_status=$?

case "$scan_status" in
  0)
    echo "placeholder-copy assertion failed:"
    printf '%s\n' "$matches"
    exit 1
    ;;
  1)
    echo "placeholder-copy assertion passed"
    ;;
  *)
    echo "placeholder-copy assertion failed: could not measure: grep exited $scan_status" >&2
    exit "$scan_status"
    ;;
esac
