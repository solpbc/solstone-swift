#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# One design iteration, captured in BOTH appearances. Builds once, then runs the
# per-surface capture twice. Writes a terminal EXIT= line to the log (shell-gotchas
# A4 — an ssh wrapper's status is not the job's).
#
#   SHOTS_PANES='home shelf' bash test/design_loop_both.sh [<out-dir>]
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

RC=0
for appearance in dark light; do
  echo "=== shots $appearance $(date -u +%FT%TZ) ===" >> "$LOG"
  SHOTS_APP="DerivedData/Build/Products/Debug-iphonesimulator/solstone-swift.app" \
  SHOTS_OUT="$OUT_DIR" \
  SHOTS_APPEARANCE="$appearance" \
    bash test/design_shots.sh >> "$LOG" 2>&1
  this=$?
  echo "SHOTS_EXIT_${appearance}=$this" >> "$LOG"
  [[ "$this" -ne 0 ]] && RC="$this"
done

echo "EXIT=$RC" >> "$LOG"
exit "$RC"
