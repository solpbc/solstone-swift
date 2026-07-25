#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ALLOWLIST_FILE="test/casing_allowlist.txt"
SCAN_ROOTS=(
  Sources
  Watch
  SolstoneWatchComplication
  SolstoneBroadcastExtension
  SolstoneLiveActivityWidget
  SolstoneNotificationContent
  SolstoneShareExtension
)

STRUCTURAL_SKIP_REGEX='accessibilityHint\(|accessibilityLabel\(|accessibilityIdentifier\(|Logger\(|Image\("|Color\("|font\(\.custom\("|subsystem:|category:'

ALLOWLIST=()

run_scan() {
  local base_dir="$1"

  (cd "$base_dir" && rg -n --pcre2 '"[A-Z]' "${SCAN_ROOTS[@]}" --glob '*.swift' --glob '!Sources/Portal/**') || true
}

path_pattern_matches() {
  local file="$1" path_pattern="$2"

  if [[ "$path_pattern" == "*" ]]; then
    return 0
  fi

  if [[ "$path_pattern" == */* ]]; then
    [[ "$file" == "$path_pattern" ]]
  else
    [[ "$file" == "$path_pattern" || "$file" == */"$path_pattern" ]]
  fi
}

classify_casing_match() {
  local file="$1" remainder="$2"
  local entry path_pattern substring

  for entry in "${ALLOWLIST[@]}"; do
    path_pattern="${entry%%|*}"
    substring="${entry#*|}"

    if path_pattern_matches "$file" "$path_pattern" && [[ "$remainder" == *"$substring"* ]]; then
      echo "allowed"
      return
    fi
  done

  echo "not-allowed"
}

load_allowlist() {
  local entry

  ALLOWLIST=()
  while IFS= read -r entry; do
    ALLOWLIST+=("$entry")
  done < <(grep -Ev '^\s*(#|$)' "$ALLOWLIST_FILE")
}

self_check_fail() {
  echo "casing self-check failed: $*" >&2
  exit 1
}

expect_path_match() {
  local expected="$1" file="$2" path_pattern="$3"
  local actual="not-matched"

  if path_pattern_matches "$file" "$path_pattern"; then
    actual="matched"
  fi

  [[ "$actual" == "$expected" ]] || self_check_fail "expected path pattern '$path_pattern' to be $expected for '$file', got $actual"
}

expect_classification() {
  local expected="$1" file="$2" remainder="$3"
  local actual

  actual="$(classify_casing_match "$file" "$remainder")"
  [[ "$actual" == "$expected" ]] || self_check_fail "expected '$file' remainder '$remainder' to be $expected, got $actual"
}

run_root_scan_self_check() {
  local fixture_root scan_output root sentinel index

  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/assert-casing.XXXXXX")"
  case "$fixture_root/" in
    "$ROOT_DIR"/*) self_check_fail "temp fixture tree landed inside the worktree: $fixture_root" ;;
  esac

  cleanup_fixture() {
    local status=$?
    rm -rf "$fixture_root"
    trap - EXIT INT TERM
    exit "$status"
  }
  trap cleanup_fixture EXIT INT TERM

  index=0
  for root in "${SCAN_ROOTS[@]}"; do
    index=$((index + 1))
    sentinel="CasingRootSentinel${index}"
    mkdir -p "$fixture_root/$root"
    printf 'let casingRootSentinel%d = "%s"\n' "$index" "$sentinel" > "$fixture_root/$root/CasingRootProbe.swift"
  done

  scan_output="$(run_scan "$fixture_root")"

  index=0
  for root in "${SCAN_ROOTS[@]}"; do
    index=$((index + 1))
    sentinel="CasingRootSentinel${index}"
    [[ "$scan_output" == *"$root/CasingRootProbe.swift:1:let casingRootSentinel${index} = \"$sentinel\""* ]] || self_check_fail "run_scan did not inspect '$root'"
  done

  rm -rf "$fixture_root"
  trap - EXIT INT TERM
}

run_self_checks() {
  echo "casing self-checks running"

  expect_path_match "matched" "Sources/MoreView.swift" "Sources/MoreView.swift"
  expect_path_match "matched" "Sources/MoreView.swift" "MoreView.swift"
  expect_path_match "not-matched" "Sources/WatchMoreView.swift" "MoreView.swift"
  expect_path_match "not-matched" "Other/Sources/MoreView.swift" "Sources/MoreView.swift"
  expect_path_match "not-matched" "OtherSources/MoreView.swift" "Sources/MoreView.swift"
  expect_path_match "matched" "Anywhere/File.swift" "*"

  ALLOWLIST=("ScreencastBroadcastWriter.swift|ScreencastBroadcastWriter")
  expect_classification "allowed" "SolstoneBroadcastExtension/ScreencastBroadcastWriter.swift" 'throw NSError(domain: "ScreencastBroadcastWriter", code: 1)'
  expect_classification "not-allowed" "SolstoneBroadcastExtension/ScreencastBroadcastWriter.swift" 'let value = "Zebra"'

  ALLOWLIST=("ShareViewController.swift|SolstoneShareExtension")
  expect_classification "allowed" "SolstoneShareExtension/ShareViewController.swift" '.appendingPathComponent("SolstoneShareExtension", isDirectory: true)'
  expect_classification "not-allowed" "SolstoneShareExtension/ShareViewController.swift" 'let value = "Zebra"'
  ALLOWLIST=()

  run_root_scan_self_check

  echo "casing self-checks passed"
}

run_self_checks
load_allowlist

RAW_MATCHES="$(run_scan "$ROOT_DIR")"
FILTERED="$(printf '%s\n' "$RAW_MATCHES" | grep -Ev "$STRUCTURAL_SKIP_REGEX" || true)"

failures=()
while IFS= read -r match; do
  [[ -z "$match" ]] && continue

  IFS=: read -r file line remainder <<<"$match"
  formatted="${file}:${line}: ${remainder}"

  if [[ "$(classify_casing_match "$file" "$remainder")" == "not-allowed" ]]; then
    failures+=("$formatted")
  fi
done <<<"$FILTERED"

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo "casing assertion failed:"
  printf '%s\n' "${failures[@]}"
  exit 1
fi

echo "casing assertion passed"
