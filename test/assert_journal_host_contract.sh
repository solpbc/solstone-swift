#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

contract_url="https://raw.githubusercontent.com/solpbc/solstone-journal/05705f731e156f8ea1956d038ec60896fdd6219e/contracts/journal-web-host/host-contract.json"
expected_sha256="96b6b5fa81608ea598f75856c3c4fd76cb79d589f1c1f48e9d079bb06166d22d"
local_contract="Sources/Portal/host-contract.json"
download="$(mktemp /var/tmp/solstone-journal-host-contract.XXXXXX)"
trap 'rm -f "$download"' EXIT

curl --fail --location --silent --show-error "$contract_url" --output "$download"
if ! cmp -s "$download" "$local_contract"; then
  echo "journal host contract assertion failed: packaged bytes differ from pinned source" >&2
  exit 1
fi

actual_sha256="$(shasum -a 256 "$download" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "journal host contract assertion failed: expected $expected_sha256, got $actual_sha256" >&2
  exit 1
fi

export_url="https://raw.githubusercontent.com/solpbc/solstone-journal/f26de8716b0d5f8b30008e56d14c3ca7f0be214e/contracts/journal-web-host/export-host-contract.json"
expected_export_sha256="7c4f637d55dc879ba980cde392f4ab5f4e4fe1ab14960f6cae20f0f91b4809fc"
local_export_contract="Sources/Portal/export-host-contract.json"
curl --fail --location --silent --show-error "$export_url" --output "$download"
if ! cmp -s "$download" "$local_export_contract"; then
  echo "journal export host contract assertion failed: packaged bytes differ from pinned source" >&2
  exit 1
fi

actual_export_sha256="$(shasum -a 256 "$download" | awk '{print $1}')"
if [[ "$actual_export_sha256" != "$expected_export_sha256" ]]; then
  echo "journal export host contract assertion failed: expected $expected_export_sha256, got $actual_export_sha256" >&2
  exit 1
fi

echo "journal host contract assertion passed"
