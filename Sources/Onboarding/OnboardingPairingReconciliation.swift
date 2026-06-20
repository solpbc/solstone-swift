// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Pure decision seam: should a successful pairing complete onboarding forward?
nonisolated final class OnboardingPairingReconciliation {
    static func shouldComplete(isPaired: Bool, isOnboardingCompleted: Bool) -> Bool {
        isPaired && !isOnboardingCompleted
    }
}
