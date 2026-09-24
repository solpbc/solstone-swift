// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class KeychainEntitlementsTests: XCTestCase {
    func testProjectYmlDeclaresKeychainAccessGroupsAndTeamPrefix() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let projectYml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        XCTAssertTrue(projectYml.contains("$(AppIdentifierPrefix)app.solstone.swift"))
        XCTAssertTrue(projectYml.contains("$(AppIdentifierPrefix)app.solstone.push"))
        XCTAssertTrue(projectYml.contains("solstoneTeamPrefix: \"$(AppIdentifierPrefix)\""))
        XCTAssertTrue(projectYml.contains("SolstoneNotificationService:"))
    }

    func testAppEntitlementsAndInfoPlistDeclareExpectedKeys() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let appEntitlementsData = try Data(contentsOf: root.appendingPathComponent("Sources/solstone-swift.entitlements"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: appEntitlementsData, options: [], format: nil) as? [String: Any])
        let groups = try XCTUnwrap(plist["keychain-access-groups"] as? [String])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0], "$(AppIdentifierPrefix)app.solstone.swift")
        XCTAssertEqual(groups[1], "$(AppIdentifierPrefix)app.solstone.push")

        let appInfo = try String(contentsOf: root.appendingPathComponent("Sources/Info.plist"), encoding: .utf8)
        XCTAssertTrue(appInfo.contains("<key>solstoneTeamPrefix</key>"))
        XCTAssertTrue(appInfo.contains("$(AppIdentifierPrefix)"))
    }

    func testServiceExtensionEntitlementsAndInfoPlistDeclareExpectedKeys() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let serviceEntitlementsData = try Data(contentsOf: root.appendingPathComponent("SolstoneNotificationService/SolstoneNotificationService.entitlements"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: serviceEntitlementsData, options: [], format: nil) as? [String: Any])
        let groups = try XCTUnwrap(plist["keychain-access-groups"] as? [String])
        XCTAssertEqual(groups, ["$(AppIdentifierPrefix)app.solstone.push"])

        let serviceInfo = try String(contentsOf: root.appendingPathComponent("SolstoneNotificationService/Info.plist"), encoding: .utf8)
        XCTAssertTrue(serviceInfo.contains("<key>solstoneTeamPrefix</key>"))
        XCTAssertTrue(serviceInfo.contains("$(AppIdentifierPrefix)"))
    }
}
