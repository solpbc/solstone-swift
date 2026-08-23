#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGETS=(
  Sources/Onboarding
  Sources/Home
  Sources/Location
  Sources/Home/ShelfPane.swift
)

status=0
while IFS=: read -r file line _; do
  end=$(( line + 60 ))
  block="$(sed -n "${line},${end}p" "$file")"
  if ! grep -Eq 'frame\(minWidth: 44, minHeight: 44(, [^)]*)?\)|frame\(maxWidth: \.infinity, minHeight: 44(, [^)]*)?\)|frame\(width: 56, height: 56\)|controlSize\(\.large\)' <<<"$block"; then
    echo "tap target sizing missing for icon-only control near ${file}:${line}"
    status=1
  fi
done < <(rg -n '\bButton\b\s*\{[^{]*$|\bButton\b\s*\{' "${TARGETS[@]}" | while IFS=: read -r file line text; do
  end=$(( line + 60 ))
  if sed -n "${line},${end}p" "$file" | rg -q 'Image\(systemName:'; then
    printf '%s:%s:%s\n' "$file" "$line" "$text"
  fi
done)

if rg -n 'Color\((red:|white:|hue:)|Color\(hex:|UIColor\((red:|white:|hue:)' "${TARGETS[@]}" >/tmp/solstone-wave5-colors.$$; then
  echo "raw color literals found in Wave 5 UI files:"
  cat /tmp/solstone-wave5-colors.$$
  rm -f /tmp/solstone-wave5-colors.$$
  exit 1
fi
rm -f /tmp/solstone-wave5-colors.$$

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo "tap target and color assertion passed"
