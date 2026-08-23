#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Capture simulator screenshots of the app across the accessibility matrix, so a
# reviewing session can look at the owner's actual pixels.
#
# Validation for the mobile-shell arc is the simulator plus screenshots. This is the
# instrument. `make screenshot` is the DEVICE path (pymobiledevice3) and is unrelated.
#
#   SHOTS_STATES='--ui-test|--ui-test --ui-test-no-journal' bash test/capture_shots.sh
#
# Every axis below was verified against the app's own SwiftUI environment values on
# 2026-08-22, not assumed:
#   appearance          simctl ui appearance light|dark                       WORKS
#   increase contrast   simctl ui increase_contrast enabled|disabled          WORKS
#   dynamic type        simctl ui content_size large|accessibility-...-large  WORKS  (AX5)
#   reduce motion       defaults write com.apple.Accessibility ...            WORKS  (toggles both ways)
#   reduce transparency  --  NOTHING WORKS.  simctl ui has no such option, and both
#                            `defaults write ... ReduceTransparencyEnabled` and
#                            `notifyutil` exit 0 and change nothing. Do not add a row
#                            for it and do not claim a Reduce Transparency result.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUNDLE_ID="${SHOTS_BUNDLE_ID:-app.solstone.swift}"
SIM_NAME="${SHOTS_SIM:-iPhone 17 Pro}"
OUT_DIR="${SHOTS_OUT:-build/shots}"
APP_PATH="${SHOTS_APP:-}"
SETTLE="${SHOTS_SETTLE:-4}"
# pipe-separated sets of launch arguments; one capture pass per set
IFS='|' read -r -a STATES <<< "${SHOTS_STATES:---ui-test}"

AX5="accessibility-extra-extra-extra-large"

log() { printf '[shots] %s\n' "$*"; }

SIM_UDID="$(xcrun simctl list devices available \
  | awk -v n="$SIM_NAME" -F'[()]' '$0 ~ n" \\(" {print $2; exit}')"
[[ -n "$SIM_UDID" ]] || { echo "[shots] no available simulator named '$SIM_NAME'" >&2; exit 1; }
log "simulator: $SIM_NAME ($SIM_UDID)"

xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1

if [[ -n "$APP_PATH" ]]; then
  xcrun simctl install "$SIM_UDID" "$APP_PATH" >/dev/null || exit 1
  log "installed $APP_PATH"
fi

set_motion() {   xcrun simctl spawn "$SIM_UDID" defaults write com.apple.Accessibility ReduceMotionEnabled -bool "$1" 2>/dev/null; }
reset_ui() {
  xcrun simctl ui "$SIM_UDID" appearance light        >/dev/null 2>&1
  xcrun simctl ui "$SIM_UDID" increase_contrast disabled >/dev/null 2>&1
  xcrun simctl ui "$SIM_UDID" content_size large      >/dev/null 2>&1
  set_motion NO
}

mkdir -p "$OUT_DIR"
CAPTURED=0
FAILED=0

capture() { # $1 = filename stem, $2.. = launch args
  local stem="$1"; shift
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1
  sleep 1
  if ! xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" "$@" >/dev/null 2>&1; then
    log "LAUNCH FAILED: $stem"; FAILED=$((FAILED+1)); return
  fi
  sleep "$SETTLE"
  local out="$OUT_DIR/$stem.png"
  if xcrun simctl io "$SIM_UDID" screenshot "$out" >/dev/null 2>&1 && [[ -s "$out" ]]; then
    CAPTURED=$((CAPTURED+1))
    printf '[shots] %-52s %s\n' "$stem" "$(wc -c <"$out" | tr -d ' ') bytes"
  else
    log "CAPTURE FAILED: $stem"; FAILED=$((FAILED+1))
  fi
}

for state_idx in "${!STATES[@]}"; do
  # shellcheck disable=SC2206
  ARGS=( ${STATES[$state_idx]} )
  slug="s${state_idx}"
  log "state $slug: ${STATES[$state_idx]}"
  for appearance in light dark; do
    xcrun simctl ui "$SIM_UDID" appearance "$appearance" >/dev/null 2>&1
    for contrast in disabled enabled; do
      xcrun simctl ui "$SIM_UDID" increase_contrast "$contrast" >/dev/null 2>&1
      for size in large "$AX5"; do
        xcrun simctl ui "$SIM_UDID" content_size "$size" >/dev/null 2>&1
        sz=$([[ "$size" == large ]] && echo default || echo ax5)
        ct=$([[ "$contrast" == disabled ]] && echo normal || echo contrast)
        capture "${slug}-${appearance}-${ct}-${sz}" "${ARGS[@]}"
      done
    done
  done
  # reduce motion gets one pass in each appearance, at default type
  xcrun simctl ui "$SIM_UDID" increase_contrast disabled >/dev/null 2>&1
  xcrun simctl ui "$SIM_UDID" content_size large >/dev/null 2>&1
  set_motion YES
  for appearance in light dark; do
    xcrun simctl ui "$SIM_UDID" appearance "$appearance" >/dev/null 2>&1
    capture "${slug}-${appearance}-reducemotion" "${ARGS[@]}"
  done
  set_motion NO
done

reset_ui
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1

log "captured $CAPTURED, failed $FAILED, into $OUT_DIR"
# A capture run that produced nothing is a failure even though every command "succeeded".
[[ "$CAPTURED" -gt 0 ]] || { echo "[shots] NOTHING WAS CAPTURED" >&2; exit 1; }
[[ "$FAILED" -eq 0 ]] || exit 1
