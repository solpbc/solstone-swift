<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 sol pbc -->

# Wave 5 Acceptance

Source list: reproduced from `mill_in.md:145+` per the approved Wave 5 design gate.

1. ✓ `make sim-json` passed with 0 errors and 0 warnings, back under the reproduced Wave 4 warning baseline.
2. ✓ `bash test/wave5_sim_smoke.sh` exercised a fresh install, completed the three-screen onboarding walk, and logged `onboarding completed` in under 120s.
3. ✗ URL-paste fallback was exercised by `integration-test-onboarding`; QR camera scan was not exercised.
4. ✓ The onboarding integration path exercised `KeychainStore.loadOrCreatePairIdentity()` before pair confirm.
5. ✓ `integration-test-onboarding` verified `POST /api/pairing/confirm`; `AppConfigTests` verified session persistence on apply.
6. ✓ `Tests/PairingClientAuthorizationTests.swift` asserted `Authorization: Bearer <session_key>` on `setBriefingTime`, `progressToday`, and `unpair`.
7. ✓ `make integration-test-onboarding` exercised both deny and grant branches, asserted `/api/push/register` on grant, and asserted it did not fire on deny.
8. ✓ `integration-test-onboarding` verified briefing-time persistence and the `tz_identifier` field.
9. ✓ `bash test/wave5_sim_smoke.sh` relaunched after onboarding and verified the shell appeared without `OnboardingRootView` logs.
10. ✓ `bash test/wave5_sim_smoke.sh` ran `UITests/PostPairStateTests.testDayZeroOverlayShowsProgressCounts` against the mock pairing server and verified the Day-0 counts plus the journal button.
11. ✓ `bash test/wave5_sim_smoke.sh` ran `UITests/PostPairStateTests.testDayOneAcknowledgmentDismissesOnce` against the mock pairing server and verified the acknowledgment rendered once and stayed dismissed after relaunch.
12. ✓ `bash test/wave5_sim_smoke.sh` used the UI-test network restore hook to verify the offline banner appears and then clears on reconnect.
13. ✓ `bash test/wave5_sim_smoke.sh` primed the portal cache and verified offline relaunch emitted `portal: loading cached html age=...`.
14. ✓ `make integration-test-observer` stayed green in Wave 5, with observer enqueue/upload evidence confirming the inherited retry/reconnect path still passes.
15. ✓ `bash test/wave5_sim_smoke.sh` verified the offline shell emitted `voice button showing disconnected shell state`.
16. ✓ `Tests/DynamicTypeSmokeTests.swift` passed for onboarding, Today/Day-0, MoreView, and SenseView at accessibility XXXL.
17. ✓ `UITests/OnboardingAccessibilityTests.swift` walked the onboarding flow and MoreView controls, and `bash test/assert_accessibility_hints.sh` verified labels/hints on the Wave 5 interactive surfaces.
18. ✓ `bash test/assert_haptics_gated.sh` verified every `UIImpactFeedbackGenerator` and `UINotificationFeedbackGenerator` call in `Sources/` is gated by `UserSettings.haptics`.
19. ✓ `bash test/assert_tap_targets.sh` verified icon-only Wave 5 controls carry 44×44 sizing hints and rejected raw color literals in the new UI files.
20. ✓ `bash test/assert_terminology.sh` passed with the approved whitelist.
21. ✓ `UITests/OnboardingAccessibilityTests.swift` verified the MoreView briefing-time, haptics, unpair, identity/about surfaces are present and accessible.
22. ✓ `UITests/UnpairFlowTests.swift` and `bash test/wave5_sim_smoke.sh` verified return-to-onboarding and observed `DELETE /api/pairing/devices/{device_id}` on the mock pairing server.
23. ✗ QR camera scan remains simulator-blocked, so not all 26 acceptance items are green in this verification pass.
24. ✓ `make integration-test`, `make integration-test-push`, `make integration-test-observer`, and `make integration-test-onboarding` all passed.
25. ✓ `AGENTS.md` was updated with the Wave 5 status blurb and terminology exceptions note.
26. ✓ New files in this lode carry SPDX/AGPL headers.

## Known follow-ups

- Portal cache warming issues a duplicate URLSession request alongside WKWebView load ([Sources/Portal/PortalPage.swift:70](/Users/jer/Library/Application%20Support/hopper/lodes/agct7f7l/worktree/Sources/Portal/PortalPage.swift:70) and [Sources/Portal/PortalPage.swift:242](/Users/jer/Library/Application%20Support/hopper/lodes/agct7f7l/worktree/Sources/Portal/PortalPage.swift:242)). Works correctly; redundant I/O. Follow-up: consolidate to a single fetch path in a future wave.
