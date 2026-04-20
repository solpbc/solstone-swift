#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

status=0
while IFS=: read -r file line _; do
  start=$(( line > 4 ? line - 4 : 1 ))
  if ! sed -n "${start},${line}p" "$file" | rg -q 'UserSettings\.haptics'; then
    echo "haptics gating missing near ${file}:${line}"
    status=1
  fi
done < <(rg -n 'UI(Notification|Impact)FeedbackGenerator\(' Sources)

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo "haptics gating assertion passed"
