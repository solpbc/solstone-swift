#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

required_hints=(
  'Sources/Onboarding/WelcomeScreen.swift:Opens the pairing step'
  'Sources/Onboarding/PairScreen.swift:Opens the camera to scan a pairing code'
  'Sources/Onboarding/PairScreen.swift:Paste the pairing URL from your desktop'
  'Sources/Onboarding/PairScreen.swift:Pairs this phone with your journal using the pasted URL'
  'Sources/Onboarding/PairScreen.swift:Returns to the welcome screen'
  'Sources/Onboarding/NotificationsScreen.swift:Requests iOS notification permission'
  'Sources/Onboarding/NotificationsScreen.swift:Continues without enabling notifications'
  'Sources/Onboarding/NotificationsScreen.swift:Returns to the pairing step'
  'Sources/Onboarding/BriefingTimeScreen.swift:Morning briefing time'
  'Sources/Onboarding/BriefingTimeScreen.swift:Saves your morning briefing time'
  'Sources/Onboarding/BriefingTimeScreen.swift:Uses the default 7 AM briefing time'
  'Sources/Onboarding/BriefingTimeScreen.swift:Returns to the notifications step'
  'Sources/Home/DayZeroOverlayView.swift:Opens Today in your journal'
  'Sources/Home/DayZeroOverlayView.swift:Dismisses this first-briefing message'
  'Sources/MoreView.swift:Chooses the time for your morning briefing'
  'Sources/MoreView.swift:Saves your morning briefing time'
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
