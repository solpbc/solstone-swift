#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# One design iteration on the build Mac: build for the simulator, then capture
# one screenshot per surface. Always writes a terminal EXIT= line to the log so
# the calling session reads the log rather than an ssh wrapper's status
# (shell-gotchas A4: `ssh host '<cmd>'` returns the wrapper's status).
#
#   bash test/design_loop.sh [<out-dir>]
#
# Env passthrough: SHOTS_PANES, SHOTS_APPEARANCE, SHOTS_SIM, SHOTS_CONTENT_SIZE.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

OUT_DIR="${1:-build/design-shots}"
LOG="$OUT_DIR/loop.log"
mkdir -p "$OUT_DIR"
: > "$LOG"

echo "=== build $(date -u +%FT%TZ) ===" >> "$LOG"
make sim >> "$LOG" 2>&1
BUILD_RC=$?
echo "BUILD_EXIT=$BUILD_RC" >> "$LOG"
if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "EXIT=$BUILD_RC" >> "$LOG"
  exit "$BUILD_RC"
fi

echo "=== shots $(date -u +%FT%TZ) ===" >> "$LOG"
SHOTS_APP="DerivedData/Build/Products/Debug-iphonesimulator/solstone-swift.app" \
SHOTS_OUT="$OUT_DIR" \
  bash test/design_shots.sh >> "$LOG" 2>&1
SHOTS_RC=$?
echo "SHOTS_EXIT=$SHOTS_RC" >> "$LOG"
echo "EXIT=$SHOTS_RC" >> "$LOG"
exit "$SHOTS_RC"
