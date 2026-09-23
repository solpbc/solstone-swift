#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Capture simulator screenshots of the Apple Watch app across watch face states.
#
#   SHOTS_PINS='off on-1h12m'          only these face states (default: all six)
#   SHOTS_SCENES='1300:--ui-test-sun-arc-denver-0923=13:00|1941-wrist-down:--ui-test-sun-arc-denver-0923=19:41 --watch-face-wrist-down'
#                                       '|'-separated "stem:launch args" scenes per state
#                                       (default: midday, night, midday wrist-down)

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUNDLE_ID="${SHOTS_BUNDLE_ID:-app.solstone.swift.watch}"
SIM_NAME="${SIM_WATCH:-Apple Watch Series 11 (46mm)}"
OUT_DIR="${SHOTS_OUT:-build/watch-shots}"
APP_PATH="${SHOTS_APP:-}"
SETTLE="${SHOTS_SETTLE:-4}"

log() { printf '[watch-shots] %s\n' "$*"; }

SIM_UDID="$(xcrun simctl list devices available \
  | grep -F "$SIM_NAME" \
  | head -n1 \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')"
[[ -n "$SIM_UDID" ]] || { echo "[watch-shots] no available simulator named '$SIM_NAME'" >&2; exit 1; }
log "simulator: $SIM_NAME ($SIM_UDID)"

xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1

if [[ -n "$APP_PATH" ]]; then
  xcrun simctl install "$SIM_UDID" "$APP_PATH" >/dev/null || exit 1
  log "installed $APP_PATH"
fi

mkdir -p "$OUT_DIR"
CAPTURED=0
FAILED=0

capture() {
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
    printf '[watch-shots] %-52s %s\n' "$stem" "$(wc -c <"$out" | tr -d ' ') bytes"
  else
    log "CAPTURE FAILED: $stem"; FAILED=$((FAILED+1))
  fi
}

PINS=(
  "off:--watch-face-off"
  "off-saved:--watch-face-off-saved"
  "setting-up:--watch-face-setting-up"
  "on-10s:--watch-face-on-10s"
  "on-1h12m:--watch-face-on-1h12m"
  "needs-attention:--watch-face-needs-attention"
)

IFS='|' read -r -a SCENES <<< "${SHOTS_SCENES:-midday:--ui-test-sun-arc-denver-midday|night:--ui-test-sun-arc-denver-night|midday-wrist-down:--ui-test-sun-arc-denver-midday --watch-face-wrist-down}"

for pin_entry in "${PINS[@]}"; do
  stem_prefix="${pin_entry%%:*}"
  pin_arg="${pin_entry#*:}"
  if [[ -n "${SHOTS_PINS:-}" && " ${SHOTS_PINS} " != *" ${stem_prefix} "* ]]; then
    continue
  fi

  for scene in "${SCENES[@]}"; do
    # shellcheck disable=SC2206
    scene_args=( ${scene#*:} )
    capture "${stem_prefix}-${scene%%:*}" "$pin_arg" "${scene_args[@]}"
  done
done

xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1

log "captured $CAPTURED, failed $FAILED, into $OUT_DIR"
[[ "$CAPTURED" -gt 0 ]] || { echo "[watch-shots] NOTHING WAS CAPTURED" >&2; exit 1; }
[[ "$FAILED" -eq 0 ]] || exit 1
