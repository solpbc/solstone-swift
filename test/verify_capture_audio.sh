#!/usr/bin/env zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Validate that a Control Center observer session produces a finalized M4A with
# the commanded duration and enough container data to rule out an empty file.
# This intentionally cannot prove that a physical microphone was connected to
# the simulator's host input.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

BUNDLE_ID="${BUNDLE_ID:-app.solstone.swift}"
SIM_UDID_FILE="${SIM_UDID_FILE:-build/manual-sim.udid}"
SCREENSHOT_DIR="${CAPTURE_AUDIO_SCREENSHOT_DIR:-build/verify-capture-audio}"

# Thirty seconds is comfortably above AC5's original ten-second floor.
TARGET_SESSION_DURATION=30
# The prior 34-second decoded measurement was 34.432 seconds (host afinfo
# estimates 34.300 seconds), so two seconds covers the observed stop skew.
TOLERANCE_SECONDS=2
# That run's 26,728-byte M4A over 34.432 seconds was about 776 bytes/second.
# Three hundred bytes/second leaves a large near-silent AAC margin while still
# rejecting an empty or header-only container.
MINIMUM_BYTES_PER_SECOND=300
MINIMUM_EXPECTED_BYTES=$((TARGET_SESSION_DURATION * MINIMUM_BYTES_PER_SECOND))
CONTROL_IDENTIFIER="SolstoneObserverCaptureControl"

log() {
    printf '[verify-capture-audio] %s\n' "$*"
}

fail() {
    printf '[verify-capture-audio] error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

for command_name in axe xcrun afinfo awk jq stat; do
    require_command "$command_name"
done

if [[ -z "${SIM_UDID:-}" ]]; then
    [[ -s "$SIM_UDID_FILE" ]] || fail "set SIM_UDID=<booted simulator UDID> or create $SIM_UDID_FILE"
    SIM_UDID="$(<"$SIM_UDID_FILE")"
fi

simulator_state="$(xcrun simctl list devices -j | jq -r --arg udid "$SIM_UDID" \
    'first(.devices[][] | select(.udid == $udid) | .state) // empty')"
[[ "$simulator_state" == "Booted" ]] || fail "simulator is not booted: $SIM_UDID"

control_value() {
    axe describe-ui --udid "$SIM_UDID" | jq -r --arg identifier "$CONTROL_IDENTIFIER" \
        '[.. | objects | select(.AXUniqueId? == $identifier) | .AXValue] | .[0] // empty'
}

wait_for_control_value() {
    local expected="$1"
    local attempts="$2"
    local current_value=""

    for _ in {1..$attempts}; do
        current_value="$(control_value)"
        [[ "$current_value" == "$expected" ]] && return 0
        sleep 0.25
    done

    fail "control did not become $expected (last value: ${current_value:-missing})"
}

open_control_center() {
    [[ -n "$(control_value)" ]] && return 0

    # Control Center opens from the top-right edge on the phone simulator.
    axe swipe --udid "$SIM_UDID" \
        --start-x 390 --start-y 5 --end-x 390 --end-y 500 \
        --duration 0.4 --post-delay 1
    [[ -n "$(control_value)" ]] || fail "Control Center does not contain $CONTROL_IDENTIFIER; add it before running this target"
}

find_finalized_audio() {
    local group_root="$1"
    local marker="$2"
    local candidate=""
    local newest=""

    while IFS= read -r candidate; do
        if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
            newest="$candidate"
        fi
    done < <(find "$group_root" -type f -name audio.m4a -newer "$marker" -print)

    [[ -n "$newest" ]] && printf '%s\n' "$newest"
}

open_control_center
current_value="$(control_value)"
[[ "$current_value" == "Off" ]] || fail "control must be Off before verification (current value: $current_value)"

group_root="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" group.app.solstone.swift)"
[[ -d "$group_root" ]] || fail "app-group container was not found for $BUNDLE_ID"

marker_file="$(mktemp /var/tmp/solstone-verify-capture-audio.XXXXXX)"
trap 'rm -f "$marker_file"' EXIT
mkdir -p "$SCREENSHOT_DIR"

log "simulator=$SIM_UDID targetSessionDuration=${TARGET_SESSION_DURATION}s toleranceSeconds=${TOLERANCE_SECONDS}s minimumExpectedBytes=$MINIMUM_EXPECTED_BYTES"
axe tap --udid "$SIM_UDID" --id "$CONTROL_IDENTIFIER" --tap-style simulator --post-delay 0
wait_for_control_value "On" 8
xcrun simctl io "$SIM_UDID" screenshot "$SCREENSHOT_DIR/session-on.png" >/dev/null

sleep "$TARGET_SESSION_DURATION"

axe tap --udid "$SIM_UDID" --id "$CONTROL_IDENTIFIER" --tap-style simulator --post-delay 0
wait_for_control_value "Off" 8
xcrun simctl io "$SIM_UDID" screenshot "$SCREENSHOT_DIR/session-off.png" >/dev/null

audio_file=""
for _ in {1..60}; do
    audio_file="$(find_finalized_audio "$group_root" "$marker_file")"
    [[ -n "$audio_file" ]] && break
    sleep 0.25
done
[[ -n "$audio_file" ]] || fail "no finalized audio.m4a appeared in the app-group container"

actual_duration="$(afinfo "$audio_file" | awk -F ': ' '/^estimated duration:/ { print $2; exit }' | awk '{ print $1 }')"
[[ -n "$actual_duration" ]] || fail "afinfo did not report a duration for $audio_file"
actual_byte_size="$(stat -f '%z' "$audio_file")"
duration_delta="$(awk -v actual="$actual_duration" -v target="$TARGET_SESSION_DURATION" 'BEGIN { delta = actual - target; if (delta < 0) delta = -delta; printf "%.6f", delta }')"

awk -v delta="$duration_delta" -v tolerance="$TOLERANCE_SECONDS" 'BEGIN { exit !(delta <= tolerance) }' || \
    fail "duration mismatch: actual=${actual_duration}s target=${TARGET_SESSION_DURATION}s tolerance=${TOLERANCE_SECONDS}s"
[[ "$actual_byte_size" -ge "$MINIMUM_EXPECTED_BYTES" ]] || \
    fail "M4A is too small: actual=${actual_byte_size} bytes minimum=${MINIMUM_EXPECTED_BYTES} bytes"

log "passed actualDuration=${actual_duration}s durationDelta=${duration_delta}s actualByteSize=${actual_byte_size} bytes"
log "audioFile=$audio_file"
log "screenshots=$SCREENSHOT_DIR/session-on.png,$SCREENSHOT_DIR/session-off.png"
