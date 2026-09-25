#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

# The app and everything it links carry no boot-time API. Apple lists
# `systemUptime` and `mach_absolute_time()` as required-reason APIs
# (NSPrivacyAccessedAPICategorySystemBootTime); no privacy manifest here
# declares that category, and the choice is to keep it that way rather than
# declare it. Elapsed time uses Date(); expiries are enforced by the peer that
# issued them. This scans the app's shipped sources AND every resolved package
# checkout, so a dependency bump cannot bring one in unnoticed. Run after a
# build that used -derivedDataPath "$DERIVED".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT_DIR"

DERIVED="${DERIVED:-DerivedData}"
checkouts="${DERIVED}/SourcePackages/checkouts"
pattern='systemUptime|mach_absolute_time'

# Fail closed: a missing checkout directory would otherwise read as "clean".
if [ ! -d "${checkouts}/spl-swift/Sources" ]; then
  echo "boot-time API assertion failed: resolved packages not found at ${checkouts}" >&2
  exit 1
fi

app_sources=()
while IFS= read -r path; do
  app_sources+=("$path")
done < <(git ls-files '*.swift' ':!Tests/' ':!UITests/' ':!WatchTests/')
if [ "${#app_sources[@]}" -eq 0 ]; then
  echo "boot-time API assertion failed: no app sources found" >&2
  exit 1
fi

# Only ripgrep exit 1 means "no match". Anything >=2 is an error and fails closed.
status=0
rg -n -e "$pattern" \
  -g '*.swift' -g '*.h' -g '*.c' -g '*.cc' -g '*.cpp' -g '*.m' -g '*.mm' \
  "${app_sources[@]}" "$checkouts" || status=$?
case "$status" in
  0)
    echo "boot-time API assertion failed: the lines above use a SystemBootTime required-reason API; use Date() instead"
    exit 1
    ;;
  1) ;;
  *)
    echo "boot-time API assertion failed: rg error (exit ${status})" >&2
    exit 1
    ;;
esac

echo "boot-time API assertion passed (${#app_sources[@]} app sources, $(ls "$checkouts" | wc -l | tr -d ' ') package checkouts)"
