#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

# Guards single-line ordinary non-raw double-quoted Swift literal segments in
# *.swift under SCAN_ROOTS. Multiline triple-quoted literals and raw Swift string
# literals such as #"..."# are outside this guard's claim. Unclassifiable matched
# lines fail loudly rather than being silently split.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ALLOWLIST_FILE="test/emdash_allowlist.txt"
SCAN_PATTERN='"[^"\n]*—[^"\n]*"'
FIELD_SEPARATOR=$'\t'
KEY_SEPARATOR=$'\t'
SCAN_ROOTS=(
  Sources
  Watch
  SolstoneWatchComplication
  SolstoneBroadcastExtension
  SolstoneLiveActivityWidget
  SolstoneNotificationContent
  SolstoneShareExtension
)

ALLOW_KEYS=()
ALLOW_COUNTS=()
SCAN_KEYS=()
SCAN_COUNTS=()
SCAN_LOCATIONS=()
failures=()
SELF_CHECK_FIXTURE_ROOT=""

self_check_fail() {
  echo "em-dash self-check failed: $*" >&2
  exit 1
}

run_scan() {
  local base_dir="$1"
  local output status

  if output="$(
    cd "$base_dir" &&
      rg -n \
        --field-match-separator "$FIELD_SEPARATOR" \
        --pcre2 "$SCAN_PATTERN" \
        "${SCAN_ROOTS[@]}" \
        --glob '*.swift' \
        2>&1
  )"; then
    status=0
  else
    status=$?
  fi

  case "$status" in
    0)
      printf '%s\n' "$output"
      ;;
    1)
      ;;
    127)
      echo "em-dash assertion failed: could not measure: rg not found" >&2
      exit 127
      ;;
    *)
      echo "em-dash assertion failed: could not measure: rg exited $status" >&2
      printf '%s\n' "$output" >&2
      exit "$status"
      ;;
  esac
}

reset_state() {
  ALLOW_KEYS=()
  SCAN_KEYS=()
  failures=()
  ALLOW_COUNTS=()
  SCAN_COUNTS=()
  SCAN_LOCATIONS=()
}

split_key_path() {
  local key="$1"
  printf '%s\n' "${key%%$KEY_SEPARATOR*}"
}

split_key_literal() {
  local key="$1"
  printf '%s\n' "${key#*$KEY_SEPARATOR}"
}

allow_index_for_key() {
  local key="$1"
  local index

  for ((index = 0; index < ${#ALLOW_KEYS[@]}; index += 1)); do
    if [[ "${ALLOW_KEYS[$index]}" == "$key" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

scan_index_for_key() {
  local key="$1"
  local index

  for ((index = 0; index < ${#SCAN_KEYS[@]}; index += 1)); do
    if [[ "${SCAN_KEYS[$index]}" == "$key" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

allow_count_for_key() {
  local key="$1"
  local index

  if index="$(allow_index_for_key "$key")"; then
    printf '%s\n' "${ALLOW_COUNTS[$index]}"
  else
    printf '0\n'
  fi
}

scan_count_for_key() {
  local key="$1"
  local index

  if index="$(scan_index_for_key "$key")"; then
    printf '%s\n' "${SCAN_COUNTS[$index]}"
  else
    printf '0\n'
  fi
}

increment_allow_count() {
  local key="$1"
  local index

  if index="$(allow_index_for_key "$key")"; then
    ALLOW_COUNTS[$index]=$((ALLOW_COUNTS[$index] + 1))
  else
    ALLOW_KEYS+=("$key")
    ALLOW_COUNTS+=(1)
  fi
}

increment_scan_count() {
  local key="$1"
  local location="$2"
  local index

  if index="$(scan_index_for_key "$key")"; then
    SCAN_COUNTS[$index]=$((SCAN_COUNTS[$index] + 1))
    SCAN_LOCATIONS[$index]+=$'\n'"$location"
  else
    SCAN_KEYS+=("$key")
    SCAN_COUNTS+=(1)
    SCAN_LOCATIONS+=("$location")
  fi
}

load_allowlist() {
  local allowlist_file="$1"
  local entry line_number path literal key

  line_number=0
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    line_number=$((line_number + 1))
    [[ "$entry" =~ ^[[:space:]]*(#|$) ]] && continue

    if [[ "$entry" != *"|"* ]]; then
      failures+=("em-dash assertion failed: invalid allowlist entry ${allowlist_file}:${line_number}: missing delimiter")
      continue
    fi

    path="${entry%%|*}"
    literal="${entry#*|}"

    if [[ -z "$path" || "$path" == /* || "$path" == ../* || "$path" == *"*"* || "$path" == *"?"* || "$path" == *"["* || "$path" == *"]"* ]]; then
      failures+=("em-dash assertion failed: invalid allowlist path ${allowlist_file}:${line_number}: $path")
      continue
    fi
    if [[ "$path" == *"$KEY_SEPARATOR"* || "$literal" == *"$KEY_SEPARATOR"* || "$literal" == *"|"* ]]; then
      failures+=("em-dash assertion failed: invalid allowlist delimiter content ${allowlist_file}:${line_number}")
      continue
    fi

    key="${path}${KEY_SEPARATOR}${literal}"
    increment_allow_count "$key"
  done < "$allowlist_file"
}

record_scan_match() {
  local file="$1"
  local line="$2"
  local literal="$3"
  local key location

  key="${file}${KEY_SEPARATOR}${literal}"
  location="${file}:${line}"
  increment_scan_count "$key" "$location"
}

parse_scan_output() {
  local scan_output="$1"
  local file line content without_quotes quote_count after_first literal

  while IFS="$FIELD_SEPARATOR" read -r file line content; do
    [[ -z "${file:-}" && -z "${line:-}" && -z "${content:-}" ]] && continue

    if [[ -z "${file:-}" || ! "${line:-}" =~ ^[0-9]+$ || -z "${content:-}" ]]; then
      failures+=("em-dash assertion failed: could not parse scan line: ${file:-}:${line:-}:${content:-}")
      continue
    fi

    without_quotes="${content//\"/}"
    quote_count=$((${#content} - ${#without_quotes}))
    if [[ "$quote_count" -ne 2 ]]; then
      failures+=("em-dash assertion failed: UNCLASSIFIABLE ${file}:${line}: quote count ${quote_count}")
      continue
    fi

    after_first="${content#*\"}"
    literal="${after_first%%\"*}"
    record_scan_match "$file" "$line" "$literal"
  done <<<"$scan_output"
}

report_surplus_scan_entries() {
  local key="$1"
  local expected="$2"
  local scan_index literal location index

  literal="$(split_key_literal "$key")"
  scan_index="$(scan_index_for_key "$key")"
  index=0
  while IFS= read -r location; do
    [[ -z "$location" ]] && continue
    index=$((index + 1))
    if [[ "$index" -gt "$expected" ]]; then
      failures+=("em-dash assertion failed: NEW VIOLATION ${location}: ${literal}")
    fi
  done <<<"${SCAN_LOCATIONS[$scan_index]}"
}

compare_multisets() {
  local index key actual expected path literal

  for ((index = 0; index < ${#SCAN_KEYS[@]}; index += 1)); do
    key="${SCAN_KEYS[$index]}"
    actual="${SCAN_COUNTS[$index]}"
    expected="$(allow_count_for_key "$key")"
    if [[ "$actual" -gt "$expected" ]]; then
      report_surplus_scan_entries "$key" "$expected"
    fi
  done

  for ((index = 0; index < ${#ALLOW_KEYS[@]}; index += 1)); do
    key="${ALLOW_KEYS[$index]}"
    expected="${ALLOW_COUNTS[$index]}"
    actual="$(scan_count_for_key "$key")"
    if [[ "$expected" -gt "$actual" ]]; then
      path="$(split_key_path "$key")"
      literal="$(split_key_literal "$key")"
      failures+=("em-dash assertion failed: STALE ENTRY ${path}|${literal} expected ${expected} actual ${actual}")
    fi
  done
}

run_assertion() {
  local base_dir="$1"
  local allowlist_file="$2"
  local scan_output

  reset_state
  load_allowlist "$allowlist_file"
  if scan_output="$(run_scan "$base_dir")"; then
    :
  else
    return $?
  fi
  parse_scan_output "$scan_output"
  compare_multisets

  if [[ "${#failures[@]}" -gt 0 ]]; then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
  return 0
}

ensure_fixture_scan_roots() {
  local fixture_root="$1"
  local root

  for root in "${SCAN_ROOTS[@]}"; do
    mkdir -p "$fixture_root/$root"
  done
}

write_behavior_fixture() {
  local fixture_root="$1"
  local mode="$2"
  local probe_file="$fixture_root/Sources/EmDashBehaviorProbe.swift"

  mkdir -p "$(dirname "$probe_file")"
  case "$mode" in
    baseline)
      printf 'let allowed = "allowed — literal"\n' > "$probe_file"
      ;;
    novel)
      printf 'let allowed = "allowed — literal"\nlet novel = "novel — literal"\n' > "$probe_file"
      ;;
    duplicate)
      printf 'let allowed = "allowed — literal"\nlet duplicate = "allowed — literal"\n' > "$probe_file"
      ;;
    stale)
      printf 'let allowed = "allowed - literal"\n' > "$probe_file"
      ;;
    moved)
      printf '\nlet allowed = "allowed — literal"\n' > "$probe_file"
      ;;
    *)
      self_check_fail "unknown behavior fixture mode: $mode"
      ;;
  esac
}

expect_assertion_pass() {
  local base_dir="$1"
  local allowlist_file="$2"
  local label="$3"
  local output

  if ! output="$(run_assertion "$base_dir" "$allowlist_file" 2>&1)"; then
    self_check_fail "expected pass for ${label}, got: ${output}"
  fi
}

expect_assertion_failure() {
  local base_dir="$1"
  local allowlist_file="$2"
  local label="$3"
  local expected_text="$4"
  local output

  if output="$(run_assertion "$base_dir" "$allowlist_file" 2>&1)"; then
    self_check_fail "expected failure for ${label}, got pass"
  fi
  [[ "$output" == *"$expected_text"* ]] || self_check_fail "expected failure for ${label} to contain '$expected_text', got: ${output}"
}

run_root_scan_self_check() {
  local fixture_root="$1"
  local allowlist_file="$fixture_root/root-allowlist.txt"
  local root index sentinel path

  mkdir -p "$fixture_root"
  ensure_fixture_scan_roots "$fixture_root"
  : > "$allowlist_file"
  index=0
  for root in "${SCAN_ROOTS[@]}"; do
    index=$((index + 1))
    sentinel="root sentinel ${index} — ${root}"
    path="${root}/EmDashRootProbe.swift"
    mkdir -p "$fixture_root/$root"
    printf 'let emDashRootSentinel%d = "%s"\n' "$index" "$sentinel" > "$fixture_root/$path"
    printf '%s|%s\n' "$path" "$sentinel" >> "$allowlist_file"
  done

  sentinel="portal sentinel — included"
  path="Sources/Portal/EmDashPortalProbe.swift"
  mkdir -p "$fixture_root/Sources/Portal"
  printf 'let emDashPortalSentinel = "%s"\n' "$sentinel" > "$fixture_root/$path"
  printf '%s|%s\n' "$path" "$sentinel" >> "$allowlist_file"

  expect_assertion_pass "$fixture_root" "$allowlist_file" "root coverage"
}

run_behavior_self_checks() {
  local fixture_root="$1"
  local allowlist_file="$fixture_root/behavior-allowlist.txt"

  mkdir -p "$fixture_root"
  ensure_fixture_scan_roots "$fixture_root"
  printf 'Sources/EmDashBehaviorProbe.swift|allowed — literal\n' > "$allowlist_file"

  write_behavior_fixture "$fixture_root" baseline
  expect_assertion_pass "$fixture_root" "$allowlist_file" "baseline"

  write_behavior_fixture "$fixture_root" novel
  expect_assertion_failure "$fixture_root" "$allowlist_file" "novel literal" "NEW VIOLATION"
  write_behavior_fixture "$fixture_root" baseline
  expect_assertion_pass "$fixture_root" "$allowlist_file" "novel literal removed"

  write_behavior_fixture "$fixture_root" duplicate
  expect_assertion_failure "$fixture_root" "$allowlist_file" "duplicate allowed literal" "NEW VIOLATION"
  write_behavior_fixture "$fixture_root" baseline
  expect_assertion_pass "$fixture_root" "$allowlist_file" "duplicate literal removed"

  write_behavior_fixture "$fixture_root" stale
  expect_assertion_failure "$fixture_root" "$allowlist_file" "stale allowlist" "STALE ENTRY"
  write_behavior_fixture "$fixture_root" baseline
  expect_assertion_pass "$fixture_root" "$allowlist_file" "stale probe restored"

  write_behavior_fixture "$fixture_root" moved
  expect_assertion_pass "$fixture_root" "$allowlist_file" "moved literal"
  write_behavior_fixture "$fixture_root" baseline
  expect_assertion_pass "$fixture_root" "$allowlist_file" "moved literal restored"
}

run_self_checks() {
  local fixture_root

  echo "em-dash self-checks running"
  SELF_CHECK_FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/assert-no-emdash.XXXXXX")"
  case "$SELF_CHECK_FIXTURE_ROOT/" in
    "$ROOT_DIR"/*) self_check_fail "temp fixture tree landed inside the worktree: $SELF_CHECK_FIXTURE_ROOT" ;;
  esac

  cleanup_fixture() {
    if [[ -n "${SELF_CHECK_FIXTURE_ROOT:-}" ]]; then
      rm -rf "$SELF_CHECK_FIXTURE_ROOT"
      SELF_CHECK_FIXTURE_ROOT=""
    fi
    trap - EXIT INT TERM
  }
  trap cleanup_fixture EXIT INT TERM

  run_root_scan_self_check "$SELF_CHECK_FIXTURE_ROOT/root-coverage"
  run_behavior_self_checks "$SELF_CHECK_FIXTURE_ROOT/behavior"

  cleanup_fixture
  echo "em-dash self-checks passed"
}

run_self_checks
run_assertion "$ROOT_DIR" "$ALLOWLIST_FILE" || exit 1
echo "em-dash assertion passed"
