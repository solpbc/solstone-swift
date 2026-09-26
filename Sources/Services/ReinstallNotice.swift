// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// iOS keeps an app's keychain when the app is deleted, so a reinstalled solstone app comes
/// back still paired, and deleting the app never told the journal anything. The owner is told
/// once, on the first launch of the reinstall, that this device is still connected, and can
/// forget the journal from there. Settings (UserDefaults) do not survive a delete, which is how
/// a reinstall is told apart from an update: an update keeps the finished onboarding.
nonisolated enum ReinstallNotice {
    static let seenKey = "solstone.install.seen.v1"

    /// Whether this launch is the first after a reinstall that kept the pairing. Marks the
    /// install as seen either way, so the answer is `true` at most once per install.
    static func isFirstLaunchAfterReinstall(
        defaults: UserDefaults = .standard,
        isPaired: Bool,
        isOnboardingCompleted: Bool
    ) -> Bool {
        let seen = defaults.bool(forKey: Self.seenKey)
        defaults.set(true, forKey: Self.seenKey)
        return !seen && isPaired && !isOnboardingCompleted
    }
}
