#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Place the three status widgets with AXe, configure the small widget for a
# non-watch source, and preserve Home and Lock Screen evidence for the four
# accessibility/appearance passes used by this lode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

AXE="${AXE:-/opt/homebrew/bin/axe}"
BUNDLE_ID="${WIDGET_SHOTS_BUNDLE_ID:-app.solstone.swift}"
SIM_NAME="${WIDGET_SHOTS_SIM:-iPhone 17 Pro}"
OUT_DIR="${WIDGET_SHOTS_OUT:-/var/tmp/solstone-widget-shots-$(basename "$ROOT_DIR")}"
APP_PATH="${WIDGET_SHOTS_APP:?set WIDGET_SHOTS_APP to the simulator app path}"
SETTLE="${WIDGET_SHOTS_SETTLE:-2}"

# These labels are supplied by the system widget gallery and customization UI.
# Keep them overridable for an iOS release that changes its accessibility copy.
WIDGET_GALLERY_LABEL="${WIDGET_GALLERY_LABEL:-solstone}"
WIDGET_EDIT_LABEL="${WIDGET_EDIT_LABEL:-Edit Widget}"
WIDGET_HOME_EDIT_LABEL="${WIDGET_HOME_EDIT_LABEL:-Edit}"
WIDGET_ADD_LABEL="${WIDGET_ADD_LABEL:-Add Widget}"
WIDGET_ADD_CONFIRM_LABEL="${WIDGET_ADD_CONFIRM_LABEL:- Add Widget}"
WIDGET_CUSTOMIZE_LABEL="${WIDGET_CUSTOMIZE_LABEL:-Customize}"

# Keep the Home Screen editor gesture separate from the small widget's
# configuration gesture. Once the small widget exists, pressing on it opens its
# context menu instead of the editor.
HOME_EDIT_X="${WIDGET_HOME_EDIT_X:-200}"
HOME_EDIT_Y="${WIDGET_HOME_EDIT_Y:-650}"
HOME_WIDGET_X="${WIDGET_HOME_WIDGET_X:-108}"
HOME_WIDGET_Y="${WIDGET_HOME_WIDGET_Y:-183}"
LOCK_WIDGET_X="${WIDGET_LOCK_WIDGET_X:-195}"
LOCK_WIDGET_Y="${WIDGET_LOCK_WIDGET_Y:-370}"
GALLERY_SEARCH_X="${WIDGET_GALLERY_SEARCH_X:-200}"
GALLERY_SEARCH_Y="${WIDGET_GALLERY_SEARCH_Y:-176}"
GALLERY_RESULT_X="${WIDGET_GALLERY_RESULT_X:-200}"
GALLERY_RESULT_Y="${WIDGET_GALLERY_RESULT_Y:-254}"
SMALL_SOURCE_X="${WIDGET_SMALL_SOURCE_X:-200}"
SMALL_SOURCE_Y="${WIDGET_SMALL_SOURCE_Y:-400}"

log() { printf '[widget-shots] %s\n' "$*"; }

[[ -x "$AXE" ]] || { echo "[widget-shots] AXe is unavailable at $AXE" >&2; exit 1; }
[[ -d "$APP_PATH" ]] || { echo "[widget-shots] simulator app not found: $APP_PATH" >&2; exit 1; }

SIM_UDID="$(xcrun simctl list devices available | awk -v n="$SIM_NAME" -F'[()]' '$0 ~ n" \\(" {print $2; exit}')"
[[ -n "$SIM_UDID" ]] || { echo "[widget-shots] no available simulator named '$SIM_NAME'" >&2; exit 1; }

mkdir -p "$OUT_DIR"
RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
exec 3>"$RUN_DIR/trace.log"
BASH_XTRACEFD=3
set -x
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
xcrun simctl install "$SIM_UDID" "$APP_PATH" >/dev/null
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null
sleep "$SETTLE"

tap_label() {
    "$AXE" tap --label "$1" --wait-timeout 10 --post-delay "$SETTLE" --udid "$SIM_UDID"
}

save_ui() {
    "$AXE" describe-ui --udid "$SIM_UDID" >"$RUN_DIR/$1.txt"
}

long_press() {
    "$AXE" touch -x "$1" -y "$2" --down --up --delay 1.2 --udid "$SIM_UDID"
    sleep "$SETTLE"
}

open_widget_gallery() {
    "$AXE" button home --udid "$SIM_UDID"
    sleep "$SETTLE"
    long_press "$HOME_EDIT_X" "$HOME_EDIT_Y"
    if "$AXE" describe-ui --udid "$SIM_UDID" | grep -Fq "\"AXLabel\" : \"$WIDGET_HOME_EDIT_LABEL\""; then
        tap_label "$WIDGET_HOME_EDIT_LABEL"
    elif "$AXE" describe-ui --udid "$SIM_UDID" | grep -Fq '"AXLabel" : "Edit Home Screen"'; then
        # SpringBoard shows a widget context menu once the screen has filled.
        # That route enters the same Home Screen editor as the empty-space menu.
        tap_label "Edit Home Screen"
    else
        echo "[widget-shots] unable to enter the Home Screen editor" >&2
        exit 1
    fi
    tap_label "$WIDGET_ADD_LABEL"
    "$AXE" tap -x "$GALLERY_SEARCH_X" -y "$GALLERY_SEARCH_Y" --post-delay "$SETTLE" --udid "$SIM_UDID"
    "$AXE" type "$WIDGET_GALLERY_LABEL" --udid "$SIM_UDID"
    sleep "$SETTLE"
    "$AXE" tap -x "$GALLERY_RESULT_X" -y "$GALLERY_RESULT_Y" --post-delay "$SETTLE" --udid "$SIM_UDID"
}

add_home_widget() {
    open_widget_gallery
    case "$1" in
    small)
        # The gallery retains the most recently selected family. Move to its
        # first page so this run always adds the small family.
        "$AXE" swipe --start-x 55 --start-y 470 --end-x 340 --end-y 470 --duration 0.4 --udid "$SIM_UDID"
        expected_size="Small"
        ;;
    medium)
        "$AXE" swipe --start-x 340 --start-y 470 --end-x 55 --end-y 470 --duration 0.4 --udid "$SIM_UDID"
        expected_size="Medium"
        ;;
    *)
        echo "[widget-shots] unknown Home Screen family: $1" >&2
        exit 1
        ;;
    esac
    sleep "$SETTLE"
    "$AXE" describe-ui --udid "$SIM_UDID" | grep -Fq "\"AXValue\" : \"Widget, $expected_size\"" || {
        echo "[widget-shots] gallery did not select ${1} widget" >&2
        exit 1
    }
    tap_label "$WIDGET_ADD_CONFIRM_LABEL"
    tap_label "Done"
    sleep "$SETTLE"
}

configure_small_widget() {
    "$AXE" button home --udid "$SIM_UDID"
    sleep "$SETTLE"
    long_press "$HOME_WIDGET_X" "$HOME_WIDGET_Y"
    tap_label "$WIDGET_EDIT_LABEL"
    # ObserverWidgetConfigurationIntent defaults to the non-watch observer
    # source; open its system configuration row before returning Home.
    "$AXE" tap -x "$SMALL_SOURCE_X" -y "$SMALL_SOURCE_Y" --post-delay "$SETTLE" --udid "$SIM_UDID"
    "$AXE" button home --udid "$SIM_UDID"
    sleep "$SETTLE"
}

add_lock_screen_widget() {
    "$AXE" button lock --udid "$SIM_UDID"
    sleep "$SETTLE"
    long_press "$LOCK_WIDGET_X" "$LOCK_WIDGET_Y"
    tap_label "$WIDGET_CUSTOMIZE_LABEL"
    tap_label "Add Widget"
    "$AXE" swipe --start-x 200 --start-y 760 --end-x 200 --end-y 430 --duration 0.4 --udid "$SIM_UDID"
    "$AXE" swipe --start-x 200 --start-y 760 --end-x 200 --end-y 430 --duration 0.4 --udid "$SIM_UDID"
    tap_label "$WIDGET_GALLERY_LABEL"
    tap_label "$WIDGET_GALLERY_LABEL"
    tap_label "close"
    sleep "$SETTLE"
}

capture_home_and_lock() {
    local stem="$1"
    "$AXE" button home --udid "$SIM_UDID"
    sleep "$SETTLE"
    save_ui "${stem}-home"
    xcrun simctl io "$SIM_UDID" screenshot "$RUN_DIR/${stem}-home.png" >/dev/null

    "$AXE" button lock --udid "$SIM_UDID"
    sleep "$SETTLE"
    save_ui "${stem}-lock"
    xcrun simctl io "$SIM_UDID" screenshot "$RUN_DIR/${stem}-lock.png" >/dev/null
}

# Place a default small widget, then a medium widget. The post-placement edit
# confirms the small widget's default observer configuration in system UI.
add_home_widget small
add_home_widget medium
configure_small_widget
add_lock_screen_widget

for pass in light dark ax5 contrast; do
    xcrun simctl ui "$SIM_UDID" appearance light >/dev/null
    xcrun simctl ui "$SIM_UDID" increase_contrast disabled >/dev/null
    xcrun simctl ui "$SIM_UDID" content_size large >/dev/null
    case "$pass" in
    dark)
        xcrun simctl ui "$SIM_UDID" appearance dark >/dev/null
        ;;
    ax5)
        xcrun simctl ui "$SIM_UDID" content_size accessibility-extra-extra-extra-large >/dev/null
        ;;
    contrast)
        xcrun simctl ui "$SIM_UDID" increase_contrast enabled >/dev/null
        ;;
    esac
    capture_home_and_lock "$pass"
done

# Leave the shared simulator in a predictable state even when the screenshots
# themselves show a failure that needs review.
xcrun simctl ui "$SIM_UDID" appearance light >/dev/null
xcrun simctl ui "$SIM_UDID" increase_contrast disabled >/dev/null
xcrun simctl ui "$SIM_UDID" content_size large >/dev/null

for image in "$RUN_DIR"/*.png; do
    [[ -s "$image" ]] || { echo "[widget-shots] missing screenshot: $image" >&2; exit 1; }
done
log "screenshots: $RUN_DIR"
