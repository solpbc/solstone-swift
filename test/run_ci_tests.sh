#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Host-side-flake-resistant test runner for `make ci`.
#
# Why this exists
# ---------------
# `xcodebuild test` for this app is intermittently flaky on the HOST RUNNER (not in
# the product, not in the test logic). Two observed shapes, both load-correlated and
# both leaving ZERO recorded test failures:
#   (a) the run wedges at 0% CPU mid-test, waiting on an accessibility element that
#       never resolves (e.g. "sources.trustLine") — the gate never returns; and
#   (b) the run reports `** TEST FAILED **` / exit 65 with 0 actual test failures
#       and a phantom "Testing started", correlating with the iOS 26.x simulator
#       runtime's `UIAccessibilityLoaderWebShared` duplicate-class instability.
# The unit tests pass and the UITest *assertions* are already bounded
# (`waitForExistence(timeout:)`), so this is the XCUITest accessibility bridge
# corrupting under contention — a runner-layer problem, not a test-logic one. The
# community-standard remedy for both is the same: bound the run with a hard timeout
# so it can never hang, and retry once on a freshly-erased simulator to clear the
# wedged accessibility state.
#
# Guarantees (these are the point — do not weaken them)
# -----------------------------------------------------
#   1. NEVER hangs indefinitely. Each attempt is bounded by a wall-clock timeout;
#      a wedged xcodebuild + test runner are killed and the sim is shut down.
#   2. TRUSTWORTHY exit code, no tail-masking. The pass/fail decision is read from
#      the .xcresult bundle's recorded `failedTests`, never grepped from stdout.
#      ANY real recorded test failure fails immediately — it is never retried and
#      never masked. A flake that persists past the retry also fails (exit != 0):
#      a green result is only ever emitted from an actual `Passed` run.
#   3. Retry is the ONLY thing the flake heuristic buys. The heuristic decides
#      "retry vs fail", never "pass vs fail".
#
# Usage:
#   bash test/run_ci_tests.sh            # the make ci gate
#   bash test/run_ci_tests.sh --selftest # validate the classification logic (no sim)
#
# Tunables come from the environment (set by the Makefile), with safe defaults here.

set -uo pipefail

PROJECT="${PROJECT:-solstone-swift.xcodeproj}"
SCHEME="${SCHEME:-solstone-swift}"
DERIVED="${DERIVED:-DerivedData}"

CI_SIM_NAME="${CI_SIM_NAME:-solstone-swift-ci}"
CI_SIM_DEVICETYPE="${CI_SIM_DEVICETYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
CI_SIM_RUNTIME="${CI_SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
CI_ATTEMPT_TIMEOUT="${CI_ATTEMPT_TIMEOUT:-1200}"   # seconds; a healthy run is ~6min
CI_MAX_ATTEMPTS="${CI_MAX_ATTEMPTS:-2}"            # 1 retry

BUILD_DIR="build"
TIMED_OUT_MARK="$BUILD_DIR/.ci-test-timed-out"

log() { printf '[ci-test] %s\n' "$*" >&2; }

# --- result-bundle classification ------------------------------------------------
#
# classify_summary <exit_code> <failed_count> <result_str> <bundle_readable:0|1>
#   echoes exactly one of: pass | real-failure | flake
#
# This is the trust-critical function. It is pure (no side effects, no sim, no I/O)
# so it can be exercised directly by --selftest.
classify_summary() {
    local rc="$1" failed="$2" result="$3" readable="$4"

    # A real recorded test failure is authoritative and final — never a flake,
    # never retried, never masked, regardless of exit code.
    if [ "$readable" = "1" ] && [ "$failed" -gt 0 ] 2>/dev/null; then
        echo "real-failure"; return
    fi

    # Clean pass: process succeeded AND the bundle recorded a Passed run with no
    # failures. Both must hold — we never call it green without a recorded pass.
    if [ "$rc" = "0" ] && [ "$readable" = "1" ] && [ "$failed" = "0" ] && [ "$result" = "Passed" ]; then
        echo "pass"; return
    fi

    # Everything else with zero recorded failures is a host-side runner flake:
    #   - timeout / wedge (no readable bundle, or rc set by our killer)
    #   - exit 65 with 0 failures and a non-"Passed" summary
    echo "flake"
}

# Read failedTests + result out of an .xcresult via xcresulttool (Xcode 16+ schema).
# Sets globals: SUMMARY_FAILED, SUMMARY_RESULT, SUMMARY_READABLE.
read_summary() {
    local bundle="$1" json
    SUMMARY_FAILED="-1"; SUMMARY_RESULT="unknown"; SUMMARY_READABLE="0"
    [ -d "$bundle" ] || return 0
    json="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null)" || return 0
    [ -n "$json" ] || return 0
    # Parse the TOP-LEVEL keys (python3 is already a build/test dependency here).
    local parsed
    parsed="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(int(d.get("failedTests", -1)), d.get("result", "unknown"))
except Exception:
    print(-1, "unknown")
' 2>/dev/null)" || parsed="-1 unknown"
    SUMMARY_FAILED="${parsed%% *}"
    SUMMARY_RESULT="${parsed##* }"
    SUMMARY_READABLE="1"
}

# --- simulator management --------------------------------------------------------

ensure_ci_sim() {
    CI_UDID="$(xcrun simctl list devices --json 2>/dev/null | python3 -c '
import sys, json
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for runtime, devs in data.get("devices", {}).items():
    for d in devs:
        if d.get("name") == name and d.get("isAvailable", False):
            print(d.get("udid", "")); sys.exit(0)
' "$CI_SIM_NAME")"

    if [ -z "${CI_UDID:-}" ]; then
        log "creating dedicated CI sim '$CI_SIM_NAME' ($CI_SIM_DEVICETYPE / $CI_SIM_RUNTIME)"
        CI_UDID="$(xcrun simctl create "$CI_SIM_NAME" "$CI_SIM_DEVICETYPE" "$CI_SIM_RUNTIME" 2>/dev/null)" || CI_UDID=""
    fi

    if [ -z "${CI_UDID:-}" ]; then
        log "FATAL: could not find or create the CI simulator"
        log "       devicetype=$CI_SIM_DEVICETYPE runtime=$CI_SIM_RUNTIME"
        log "       check: xcrun simctl list devicetypes | grep '17 Pro' ; xcrun simctl list runtimes"
        exit 3
    fi
    log "CI sim: $CI_SIM_NAME ($CI_UDID)"
}

# Bring the sim to a clean state before an attempt. On a retry we ERASE it, which
# wipes the wedged accessibility-loader daemon state that drove the flake.
prepare_sim() {
    local attempt="$1"
    xcrun simctl shutdown "$CI_UDID" >/dev/null 2>&1 || true
    if [ "$attempt" -gt 1 ]; then
        log "erasing CI sim to clear wedged accessibility/runner state before retry"
        xcrun simctl erase "$CI_UDID" >/dev/null 2>&1 || true
    fi
}

# --- one bounded attempt ---------------------------------------------------------

run_attempt() {
    local attempt="$1"
    local bundle="$BUILD_DIR/ci-test-attempt-$attempt.xcresult"
    local logf="$BUILD_DIR/ci-test-attempt-$attempt.log"
    rm -rf "$bundle" "$TIMED_OUT_MARK"
    mkdir -p "$BUILD_DIR"

    log "attempt $attempt/$CI_MAX_ATTEMPTS — xcodebuild test (timeout ${CI_ATTEMPT_TIMEOUT}s) → $logf"

    xcodebuild test \
        -project "$PROJECT" -scheme "$SCHEME" \
        -skipMacroValidation \
        -destination "platform=iOS Simulator,id=$CI_UDID" \
        -derivedDataPath "$DERIVED" \
        -resultBundlePath "$bundle" \
        >"$logf" 2>&1 &
    local xb_pid=$!

    # Watchdog: if the run is still alive at the deadline, it is wedged — kill the
    # whole tree and mark the attempt as timed out so it classifies as a flake.
    (
        local waited=0
        while [ "$waited" -lt "$CI_ATTEMPT_TIMEOUT" ]; do
            kill -0 "$xb_pid" 2>/dev/null || exit 0
            sleep 5
            waited=$((waited + 5))
        done
        if kill -0 "$xb_pid" 2>/dev/null; then
            touch "$TIMED_OUT_MARK"
            log "attempt $attempt exceeded ${CI_ATTEMPT_TIMEOUT}s at the runner — killing wedged xcodebuild + test runner"
            kill -TERM "$xb_pid" 2>/dev/null || true
            sleep 3
            kill -9 "$xb_pid" 2>/dev/null || true
            pkill -9 -f "XCTRunner" 2>/dev/null || true
            pkill -9 -f "xctest"    2>/dev/null || true
            xcrun simctl shutdown "$CI_UDID" >/dev/null 2>&1 || true
        fi
    ) &
    local killer=$!

    wait "$xb_pid"; local rc=$?
    kill "$killer" 2>/dev/null || true
    wait "$killer" 2>/dev/null || true

    LAST_BUNDLE="$bundle"
    LAST_LOG="$logf"
    LAST_RC="$rc"
    [ -f "$TIMED_OUT_MARK" ] && LAST_TIMED_OUT=1 || LAST_TIMED_OUT=0
    return 0
}

# --- selftest (no simulator needed) ----------------------------------------------
# Exercises the trust-critical classifier against every shape we care about.
selftest() {
    local fails=0
    check() { # <desc> <expected> <got>
        if [ "$2" = "$3" ]; then
            printf 'ok   - %s\n' "$1"
        else
            printf 'FAIL - %s (expected %s, got %s)\n' "$1" "$2" "$3"; fails=$((fails + 1))
        fi
    }
    # rc, failed, result, readable
    check "clean pass"                         pass         "$(classify_summary 0 0 Passed 1)"
    check "real failure, nonzero exit"         real-failure "$(classify_summary 65 2 Failed 1)"
    check "real failure even if exit 0"        real-failure "$(classify_summary 0 1 Failed 1)"
    check "real failure is never masked"       real-failure "$(classify_summary 65 7 Failed 1)"
    check "flake: exit 65, zero failures"      flake        "$(classify_summary 65 0 unknown 1)"
    check "flake: timeout, no bundle"          flake        "$(classify_summary 143 -1 unknown 0)"
    check "flake: nonzero exit, passed-ish"    flake        "$(classify_summary 1 0 Passed 0)"
    check "not green w/o recorded pass"        flake        "$(classify_summary 0 0 unknown 0)"
    echo
    if [ "$fails" -eq 0 ]; then
        echo "[ci-test] selftest: all checks passed"; return 0
    fi
    echo "[ci-test] selftest: $fails check(s) FAILED"; return 1
}

# --- main ------------------------------------------------------------------------

if [ "${1:-}" = "--selftest" ]; then
    selftest; exit $?
fi

ensure_ci_sim

attempt=1
while [ "$attempt" -le "$CI_MAX_ATTEMPTS" ]; do
    prepare_sim "$attempt"
    run_attempt "$attempt"
    read_summary "$LAST_BUNDLE"

    # A watchdog timeout is, by definition, a wedge → force the flake path.
    if [ "$LAST_TIMED_OUT" = "1" ]; then
        verdict="flake"
    else
        verdict="$(classify_summary "$LAST_RC" "$SUMMARY_FAILED" "$SUMMARY_RESULT" "$SUMMARY_READABLE")"
    fi

    case "$verdict" in
        pass)
            log "PASS on attempt $attempt ($SUMMARY_RESULT, failedTests=$SUMMARY_FAILED)"
            exit 0
            ;;
        real-failure)
            log "REAL test failure(s) on attempt $attempt (failedTests=$SUMMARY_FAILED) — not a runner flake; failing without retry"
            echo "----- tail of $LAST_LOG -----" >&2
            tail -n 40 "$LAST_LOG" >&2 || true
            exit 1
            ;;
        flake)
            log "host-side runner flake on attempt $attempt (exit=$LAST_RC, failedTests=$SUMMARY_FAILED, timedOut=$LAST_TIMED_OUT, no recorded test failures)"
            if [ "$attempt" -lt "$CI_MAX_ATTEMPTS" ]; then
                log "retrying once on a freshly-erased sim…"
            fi
            ;;
    esac
    attempt=$((attempt + 1))
done

log "runner flake persisted across $CI_MAX_ATTEMPTS attempts — failing (NOT masking; surface for investigation)"
echo "----- tail of $LAST_LOG -----" >&2
tail -n 40 "$LAST_LOG" >&2 || true
exit 2
