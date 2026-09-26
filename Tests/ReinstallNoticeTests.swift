// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ReinstallNoticeTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "ReinstallNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A reinstall comes back paired (the keychain survives a delete) with settings wiped, so
    /// onboarding reads unfinished. The owner is told once, and never again on that install.
    func testAReinstallThatKeptThePairingIsToldOnce() {
        let defaults = self.freshDefaults()
        XCTAssertTrue(ReinstallNotice.isFirstLaunchAfterReinstall(defaults: defaults, isPaired: true, isOnboardingCompleted: false))
        XCTAssertFalse(ReinstallNotice.isFirstLaunchAfterReinstall(defaults: defaults, isPaired: true, isOnboardingCompleted: false))
    }

    /// An update keeps settings, so onboarding is finished: no notice, even on the first launch
    /// of the build that introduced it.
    func testAnUpdateIsNotAReinstall() {
        let defaults = self.freshDefaults()
        XCTAssertFalse(ReinstallNotice.isFirstLaunchAfterReinstall(defaults: defaults, isPaired: true, isOnboardingCompleted: true))
    }

    func testAFreshUnpairedInstallIsNotAReinstall() {
        let defaults = self.freshDefaults()
        XCTAssertFalse(ReinstallNotice.isFirstLaunchAfterReinstall(defaults: defaults, isPaired: false, isOnboardingCompleted: false))
        XCTAssertFalse(
            ReinstallNotice.isFirstLaunchAfterReinstall(defaults: defaults, isPaired: true, isOnboardingCompleted: false),
            "pairing later in onboarding on a fresh install is not a reinstall"
        )
    }
}
