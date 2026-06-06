#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT_DIR"

# Checks the GENERATED Sources/Info.plist -- the literal file xcodegen builds into
# the product -- which (unlike the deleted build setting) would have caught build
# 1's silent drop.
if ! modes_json="$(plutil -extract UIBackgroundModes json -o - Sources/Info.plist 2>/dev/null)"; then
  echo "background modes assertion failed: UIBackgroundModes missing from generated Sources/Info.plist"
  exit 1
fi

if ! printf '%s' "$modes_json" | python3 -c '
import json
import sys

expected = {"audio", "fetch", "location", "remote-notification"}

try:
    modes = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

if not isinstance(modes, list) or len(modes) != 4 or set(modes) != expected:
    sys.exit(1)
'; then
  echo "background modes assertion failed: expected exactly audio, fetch, location, remote-notification; got ${modes_json}"
  exit 1
fi

echo "background modes assertion passed"
