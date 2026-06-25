#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

required_hints=(
  'Sources/Onboarding/WelcomeScreen.swift:opens the first source step'
  'Sources/Location/LocationSourceDetailView.swift:Opens iOS Settings for location access.'
  'Sources/Location/LocationSourceDetailView.swift:Changes the detail level to what iOS allows.'
  'Sources/Location/LocationSourceDetailView.swift:Resumes location updates to your journal.'
  'Sources/Location/LocationSourceDetailView.swift:Pauses location updates to your journal.'
  'Sources/Location/LocationSourceDetailView.swift:Tries sending location updates again.'
  "Sources/Location/LocationSourceDetailView.swift:Removes location's contributions from your journal."
  'Sources/Location/LocationSourceDetailView.swift:Opens your journal inside solstone.'
  'Sources/Location/LocationSourceDetailView.swift:Uses places only from now on.'
  'Sources/Location/LocationSourceDetailView.swift:Uses places plus comings and goings from now on. This is the recommended default.'
  'Sources/Location/LocationSourceDetailView.swift:Uses the complete picture from now on.'
  'Sources/Location/LocationSourceDetailView.swift:Starts adding location updates to your journal.'
  'Sources/Location/LocationSourceDetailView.swift:Continues to the iOS location permission step.'
  'Sources/Location/LocationSourceDetailView.swift:Chooses places only for location.'
  'Sources/Location/LocationSourceDetailView.swift:Chooses places plus comings and goings for location. This is the recommended default.'
  'Sources/Location/LocationSourceDetailView.swift:Chooses the complete picture for location.'
  'Sources/MoreView.swift:Turns interface haptics on or off'
  'Sources/MoreView.swift:Clears this device pairing and returns to onboarding'
  'Sources/Voice/VoiceButton.swift:starts a voice session'
)

for entry in "${required_hints[@]}"; do
  file="${entry%%:*}"
  hint="${entry#*:}"
  rg -q "accessibility(Hint|Label)\\(\"${hint//\//\\/}\"|\"${hint//\//\\/}\"" "$file" || {
    echo "missing accessibility metadata in $file: $hint"
    exit 1
  }
done

echo "accessibility hint assertion passed"
