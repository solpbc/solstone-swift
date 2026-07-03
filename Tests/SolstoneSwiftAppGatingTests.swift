// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import XCTest

final class SolstoneSwiftAppGatingTests: XCTestCase {
    func testLaunchMaintenanceGateRequiresActiveScenePhase() {
        XCTAssertFalse(SolstoneSwiftApp.shouldRunLaunchMaintenance(scenePhase: .background))
        XCTAssertFalse(SolstoneSwiftApp.shouldRunLaunchMaintenance(scenePhase: .inactive))
    }

    func testLaunchMaintenanceGateSuppressesUnitTests() {
        // XCTest sets xctestconfigurationfilepath in the process environment, so the in-process
        // .active assertion verifies the unit-test suppression path rather than normal app runtime.
        XCTAssertFalse(SolstoneSwiftApp.shouldRunLaunchMaintenance(scenePhase: .active))
    }
}
