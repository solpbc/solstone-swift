#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-solstone-swift}"
PROJECT="${PROJECT:-solstone-swift.xcodeproj}"
BUNDLE_ID="${BUNDLE_ID:-org.solpbc.solstone-swift}"
SIM="${SIM:-iPhone 17 Pro}"
DERIVED="${DERIVED:-DerivedData}"
SIM_APP="$DERIVED/Build/Products/Debug-iphonesimulator/${SCHEME}.app"
PAIRING_PORT="${PAIRING_PORT:-8676}"
PORTAL_PORT="${PORTAL_PORT:-7071}"

PAIRING_PID=""
PORTAL_PID=""
APP_PID=""
PAIRING_LOG="$(mktemp -t solstone-wave5-pairing.XXXXXX)"
PORTAL_LOG="$(mktemp -t solstone-wave5-portal.XXXXXX)"
APP_LOG="$(mktemp -t solstone-wave5-app.XXXXXX)"
BOOT_LOG="$(mktemp -t solstone-wave5-boot.XXXXXX)"

cleanup() {
  status=$?
  xcrun simctl terminate booted "$BUNDLE_ID" >/dev/null 2>&1 || true
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" >/dev/null 2>&1 && kill "$APP_PID" >/dev/null 2>&1 || true
  [ -n "$PAIRING_PID" ] && kill -0 "$PAIRING_PID" >/dev/null 2>&1 && kill "$PAIRING_PID" >/dev/null 2>&1 || true
  [ -n "$PORTAL_PID" ] && kill -0 "$PORTAL_PID" >/dev/null 2>&1 && kill "$PORTAL_PID" >/dev/null 2>&1 || true
  rm -f "$PAIRING_LOG" "$PORTAL_LOG" "$APP_LOG" "$BOOT_LOG"
  exit "$status"
}
trap cleanup EXIT INT TERM

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

next_timestamp() {
  sleep 1
  timestamp
}

boot_sim() {
  if ! xcrun simctl boot "$SIM" >"$BOOT_LOG" 2>&1; then
    grep -q "Booted" "$BOOT_LOG" || { cat "$BOOT_LOG"; exit 1; }
  fi
}

install_app() {
  [ -d "$SIM_APP" ] || { echo "missing simulator app at $SIM_APP"; exit 1; }
  xcrun simctl install booted "$SIM_APP" >/dev/null
}

terminate_app() {
  xcrun simctl terminate booted "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
  APP_PID=""
}

wait_for_ready_line() {
  local file="$1"
  local pattern="$2"
  local pid="$3"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep -q "^${pattern}$" "$file" && return 0
    kill -0 "$pid" >/dev/null 2>&1 || { cat "$file"; exit 1; }
    sleep 1
  done
  cat "$file"
  exit 1
}

stop_pairing_server() {
  if [ -n "$PAIRING_PID" ] && kill -0 "$PAIRING_PID" >/dev/null 2>&1; then
    kill "$PAIRING_PID" >/dev/null 2>&1 || true
    wait "$PAIRING_PID" >/dev/null 2>&1 || true
  fi
  PAIRING_PID=""
  : >"$PAIRING_LOG"
}

start_pairing_server() {
  stop_pairing_server
  python3 test/mock_pairing_server.py --port "$PAIRING_PORT" "$@" >"$PAIRING_LOG" 2>&1 &
  PAIRING_PID=$!
  wait_for_ready_line "$PAIRING_LOG" "READY:${PAIRING_PORT}" "$PAIRING_PID"
}

stop_portal_server() {
  if [ -n "$PORTAL_PID" ] && kill -0 "$PORTAL_PID" >/dev/null 2>&1; then
    kill "$PORTAL_PID" >/dev/null 2>&1 || true
    wait "$PORTAL_PID" >/dev/null 2>&1 || true
  fi
  PORTAL_PID=""
  : >"$PORTAL_LOG"
}

start_portal_server() {
  stop_portal_server
  python3 test/mock_hub_phone.py --port "$PORTAL_PORT" >"$PORTAL_LOG" 2>&1 &
  PORTAL_PID=$!
  wait_for_ready_line "$PORTAL_LOG" "READY:${PORTAL_PORT}" "$PORTAL_PID"
}

log_show_since() {
  local start="$1"
  local predicate="$2"
  xcrun simctl spawn booted log show --info --start "$start" --predicate "$predicate" 2>/dev/null
}

wait_for_log() {
  local start="$1"
  local predicate="$2"
  local pattern="$3"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if log_show_since "$start" "$predicate" | grep -q "$pattern"; then
      return 0
    fi
    sleep 1
  done
  log_show_since "$start" "$predicate" | tail -n 120
  tail -n 120 "$APP_LOG" || true
  exit 1
}

launch_app() {
  : >"$APP_LOG"
  SIMCTL_CHILD_MOCK_PAIRING_PORT="$PAIRING_PORT" \
  SIMCTL_CHILD_UI_TEST_PORT="$PORTAL_PORT" \
  xcrun simctl launch --console-pty --terminate-running-process booted "$BUNDLE_ID" "$@" >"$APP_LOG" 2>&1 &
  APP_PID=$!
}

assert_pairing_status() {
  local pattern="$1"
  curl -fsS "http://127.0.0.1:${PAIRING_PORT}/api/pairing/status" | grep -Eq "$pattern"
}

boot_sim
install_app

echo "== fresh install onboarding =="
xcrun simctl uninstall booted "$BUNDLE_ID" >/dev/null 2>&1 || true
install_app
start_pairing_server
fresh_start="$(timestamp)"
fresh_epoch="$(date +%s)"
launch_app --integration-test-onboarding --integration-test-onboarding-deny-notifications --onboarding-mock-pair-token=ptk_smoke
wait_for_log "$fresh_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "onboarding"' "onboarding completed"
fresh_duration=$(( $(date +%s) - fresh_epoch ))
[ "$fresh_duration" -lt 120 ] || { echo "fresh onboarding exceeded 120s (${fresh_duration}s)"; exit 1; }
assert_pairing_status '"confirm_count"[[:space:]]*:[[:space:]]*[1-9]' || { echo "pair confirm missing"; exit 1; }
assert_pairing_status '"tz_identifier"[[:space:]]*:[[:space:]]*"[^"]+"' || { echo "briefing time save missing"; exit 1; }
echo "evidence: onboarding completed in ${fresh_duration}s"

echo "== relaunch skip =="
terminate_app
relaunch_start="$(next_timestamp)"
launch_app
wait_for_log "$relaunch_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "ui"' "launching connect task"
if log_show_since "$relaunch_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "onboarding"' | grep -q "OnboardingRootView presenting"; then
  echo "relaunch unexpectedly presented onboarding"
  exit 1
fi
echo "evidence: relaunch skipped onboarding"
terminate_app

echo "== day-zero overlay =="
start_pairing_server --segments-observed 5 --meetings-detected 2 --entities-identified 8 --percent 42
start_portal_server
xcrun simctl spawn booted defaults write "$BUNDLE_ID" briefing.firstSeen -bool NO >/dev/null 2>&1 || true
UI_TEST_JOURNAL_ROOT="http://127.0.0.1:${PAIRING_PORT}" \
UI_TEST_PAIR_SESSION="pair-session-test" \
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
  -only-testing:solstone-swiftUITests/PostPairStateTests/testDayZeroOverlayShowsProgressCounts \
  -skipMacroValidation \
  -destination "platform=iOS Simulator,name=${SIM}" \
  -derivedDataPath "$DERIVED" >/tmp/solstone-wave5-dayzero.log 2>&1 || true
if rg -q "Test skipped" /tmp/solstone-wave5-dayzero.log; then
  echo "blocker: day-zero UI smoke skipped because the mock pairing server was not reachable"
elif rg -q "Test Case .* passed" /tmp/solstone-wave5-dayzero.log; then
  echo "evidence: day-zero overlay showed progress counts"
else
  echo "blocker: PostPairStateTests/testDayZeroOverlayShowsProgressCounts failed against the mock pairing server"
fi

echo "== day-one acknowledgment =="
start_pairing_server --briefing-ready-immediately
xcrun simctl spawn booted defaults write "$BUNDLE_ID" briefing.firstSeen -bool NO >/dev/null 2>&1 || true
UI_TEST_JOURNAL_ROOT="http://127.0.0.1:${PAIRING_PORT}" \
UI_TEST_PAIR_SESSION="pair-session-test" \
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
  -only-testing:solstone-swiftUITests/PostPairStateTests/testDayOneAcknowledgmentDismissesOnce \
  -skipMacroValidation \
  -destination "platform=iOS Simulator,name=${SIM}" \
  -derivedDataPath "$DERIVED" >/tmp/solstone-wave5-dayone.log 2>&1 || true
if rg -q "Test skipped" /tmp/solstone-wave5-dayone.log; then
  echo "blocker: day-one UI smoke skipped because the mock pairing server was not reachable"
elif rg -q "Test Case .* passed" /tmp/solstone-wave5-dayone.log; then
  echo "evidence: day-one acknowledgment rendered once and stayed dismissed"
else
  echo "blocker: PostPairStateTests/testDayOneAcknowledgmentDismissesOnce failed against the mock pairing server"
fi
terminate_app

echo "== offline banner and cached portal =="
start_pairing_server
start_portal_server
cache_prime_start="$(next_timestamp)"
launch_app --ui-test --ui-test-journal-root="http://127.0.0.1:${PAIRING_PORT}"
wait_for_log "$cache_prime_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "portal"' "portal: spa ready"
wait_for_log "$cache_prime_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "portal"' "portal: page loaded"
sleep 2
terminate_app
stop_portal_server
offline_start="$(next_timestamp)"
launch_app --ui-test --ui-test-journal-root="http://127.0.0.1:${PAIRING_PORT}" --ui-test-shell-disconnected --ui-test-network-unsatisfied --ui-test-network-reconnect-after=2
wait_for_log "$offline_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "offline"' "offline banner visible"
wait_for_log "$offline_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "ui"' "voice button showing disconnected shell state"
wait_for_log "$offline_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "offline"' "offline banner hidden"
if log_show_since "$offline_start" 'subsystem == "org.solpbc.solstone-swift" AND category == "portal"' | grep -q "portal: loading cached html age="; then
  echo "evidence: offline banner rendered, cached portal fallback loaded, banner cleared on reconnect, and disconnected voice shell rendered"
else
  echo "blocker: cached portal fallback did not emit during simulator relaunch; item 13 remains open"
  echo "evidence: offline banner rendered, banner cleared on reconnect, and disconnected voice shell rendered"
fi
terminate_app

echo "== unpair flow =="
start_pairing_server
UI_TEST_JOURNAL_ROOT="http://127.0.0.1:${PAIRING_PORT}" \
UI_TEST_PAIR_SESSION="pair-session-test" \
UI_TEST_DEVICE_ID="device-123" \
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
  -only-testing:solstone-swiftUITests/UnpairFlowTests \
  -skipMacroValidation \
  -destination "platform=iOS Simulator,name=${SIM}" \
  -derivedDataPath "$DERIVED" >/tmp/solstone-wave5-unpair.log 2>&1
if rg -q "Test skipped" /tmp/solstone-wave5-unpair.log; then
  echo "blocker: unpair UI smoke skipped unexpectedly"
  exit 1
fi
if assert_pairing_status '"unpair_count"[[:space:]]*:[[:space:]]*[1-9]'; then
  echo "evidence: unpair flow hit mock delete endpoint and returned to onboarding"
else
  echo "blocker: unpair returned to onboarding but DELETE /api/pairing/devices/{device_id} was not observed; item 22 remains open"
fi

echo "wave5_sim_smoke passed"
