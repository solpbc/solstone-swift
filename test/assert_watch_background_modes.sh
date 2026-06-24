#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT_DIR"

if ! modes_json="$(plutil -extract UIBackgroundModes json -o - Watch/Info.plist 2>/dev/null)"; then
  echo "watch background modes assertion failed: UIBackgroundModes missing from generated Watch/Info.plist"
  exit 1
fi

if ! printf '%s' "$modes_json" | python3 -c '
import json
import sys

expected = {"audio", "location"}

try:
    modes = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

if not isinstance(modes, list) or len(modes) != 2 or set(modes) != expected:
    sys.exit(1)
'; then
  echo "watch background modes assertion failed: expected exactly audio, location; got ${modes_json}"
  exit 1
fi

echo "watch background modes assertion passed"
