#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Design-iteration screenshot instrument: one shot per SURFACE, at a single
# appearance/type size, so a design session can look at every screen it just
# changed in one pass.
#
# This is the sibling of test/capture_shots.sh, not a replacement:
#   capture_shots.sh  = one surface (launch state) x the full a11y matrix. Conformance.
#   design_shots.sh   = every surface x one appearance. Visual iteration.
#
#   SHOTS_APP=... SHOTS_SIM='iPhone 17 Pro' SHOTS_APPEARANCE=dark \
#     SHOTS_PANES='home shelf status addMore import source:audio' \
#     bash test/design_shots.sh
#
# Writes $OUT_DIR/<appearance>-<pane>.png and an EXIT= line into $OUT_DIR/run.log
# so the caller reads the log rather than an ssh wrapper's status (shell-gotchas A4).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

BUNDLE_ID="${SHOTS_BUNDLE_ID:-app.solstone.swift}"
SIM_NAME="${SHOTS_SIM:-iPhone 17 Pro}"
OUT_DIR="${SHOTS_OUT:-build/design-shots}"
APP_PATH="${SHOTS_APP:-}"
SETTLE="${SHOTS_SETTLE:-4}"
APPEARANCE="${SHOTS_APPEARANCE:-dark}"
CONTENT_SIZE="${SHOTS_CONTENT_SIZE:-large}"
read -r -a PANES <<< "${SHOTS_PANES:-home shelf status addMore import source:audio source:watch}"

# Base launch args every pane shares: seeded fixture + a journal mark so the
# journal pill renders its real paired treatment rather than the unpaired stub.
read -r -a BASE_ARGS <<< "${SHOTS_BASE_ARGS:---ui-test --ui-test-journal-mark}"

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"
: > "$LOG"

log() { printf '[design-shots] %s\n' "$*" | tee -a "$LOG"; }

SIM_UDID="$(xcrun simctl list devices available \
  | awk -v n="$SIM_NAME" -F'[()]' '$0 ~ n" \\(" {print $2; exit}')"
if [[ -z "$SIM_UDID" ]]; then
  log "no available simulator named '$SIM_NAME'"
  echo "EXIT=1" >> "$LOG"; exit 1
fi
log "simulator: $SIM_NAME ($SIM_UDID)"

xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1

if [[ -n "$APP_PATH" ]]; then
  if ! xcrun simctl install "$SIM_UDID" "$APP_PATH" >/dev/null 2>&1; then
    log "install FAILED: $APP_PATH"
    echo "EXIT=1" >> "$LOG"; exit 1
  fi
  log "installed $APP_PATH"
fi

xcrun simctl ui "$SIM_UDID" appearance "$APPEARANCE"       >/dev/null 2>&1
xcrun simctl ui "$SIM_UDID" content_size "$CONTENT_SIZE"   >/dev/null 2>&1
xcrun simctl ui "$SIM_UDID" increase_contrast disabled     >/dev/null 2>&1

CAPTURED=0
FAILED=0

for pane in "${PANES[@]}"; do
  args=( "${BASE_ARGS[@]}" )
  [[ "$pane" != "home" ]] && args+=( "--ui-test-open-pane=$pane" )

  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1
  sleep 1
  if ! xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" "${args[@]}" >/dev/null 2>&1; then
    log "LAUNCH FAILED: $pane"; FAILED=$((FAILED+1)); continue
  fi
  sleep "$SETTLE"
  out="$OUT_DIR/${APPEARANCE}-${pane//:/-}.png"
  if xcrun simctl io "$SIM_UDID" screenshot "$out" >/dev/null 2>&1 && [[ -s "$out" ]]; then
    CAPTURED=$((CAPTURED+1))
    log "$(printf '%-28s %s bytes' "$pane" "$(wc -c <"$out" | tr -d ' ')")"
  else
    log "CAPTURE FAILED: $pane"; FAILED=$((FAILED+1))
  fi
done

log "captured=$CAPTURED failed=$FAILED out=$OUT_DIR"
[[ "$FAILED" -eq 0 ]] && echo "EXIT=0" >> "$LOG" || echo "EXIT=1" >> "$LOG"
[[ "$FAILED" -eq 0 ]]
