// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import UIKit
import XCTest

nonisolated final class SolstoneSceneDelegateTests: XCTestCase {
    @MainActor
    func testLastWillConnectIsRecorded() throws {
        let record = try XCTUnwrap(SolstoneSceneDelegate.lastWillConnect)
        XCTAssertEqual(record.sessionRoleRawValue, UISceneSession.Role.windowApplication.rawValue)
    }

    @MainActor
    func testSizeRestrictionsPresenceMatchesIdiom() throws {
        let record = try XCTUnwrap(SolstoneSceneDelegate.lastWillConnect)
        XCTAssertEqual(record.hadSizeRestrictions, UIDevice.current.userInterfaceIdiom == .pad)
        if record.hadSizeRestrictions {
            XCTAssertNotNil(record.appliedMinimumSize)
        } else {
            XCTAssertNil(record.appliedMinimumSize)
        }
    }
}
