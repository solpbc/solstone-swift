#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ALLOWLIST_FILE="test/casing_allowlist.txt"
SCAN_CMD=(rg -n --pcre2 '"[A-Z]' Sources --glob '*.swift' --glob '!Sources/Portal/**')
RAW_MATCHES="$("${SCAN_CMD[@]}" || true)"

STRUCTURAL_SKIP_REGEX='accessibilityHint\(|accessibilityLabel\(|accessibilityIdentifier\(|Logger\(|Image\("|Color\("|font\(\.custom\("|subsystem:|category:'
FILTERED="$(printf '%s\n' "$RAW_MATCHES" | grep -Ev "$STRUCTURAL_SKIP_REGEX" || true)"

ALLOWLIST=()
while IFS= read -r entry; do
  ALLOWLIST+=("$entry")
done < <(grep -Ev '^\s*(#|$)' "$ALLOWLIST_FILE")

failures=()
while IFS= read -r match; do
  [[ -z "$match" ]] && continue

  IFS=: read -r file line remainder <<<"$match"
  formatted="${file}:${line}: ${remainder}"
  skipped=0

  for entry in "${ALLOWLIST[@]}"; do
    path_pattern="${entry%%|*}"
    substring="${entry#*|}"
    if [[ "$path_pattern" == "*" || "$file" == *"$path_pattern" ]]; then
      if [[ "$formatted" == *"$substring"* ]]; then
        skipped=1
        break
      fi
    fi
  done

  if [[ "$skipped" -eq 0 ]]; then
    failures+=("$formatted")
  fi
done <<<"$FILTERED"

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo "casing assertion failed:"
  printf '%s\n' "${failures[@]}"
  exit 1
fi

echo "casing assertion passed"
