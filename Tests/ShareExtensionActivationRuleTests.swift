// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ShareExtensionActivationRuleTests: XCTestCase {
    func testPlainTextActivationRuleIsPresentInProjectAndPlist() throws {
        let projectYML = try String(contentsOf: Self.projectYMLURL(), encoding: .utf8)
        let infoPlist = try String(contentsOf: Self.infoPlistURL(), encoding: .utf8)
        // project.yml generates the plist; the two must carry the same rule. What the rule admits is
        // tested by evaluating it (ShareImportCoordinatorTests.testShareSheetOffersAnyFileButNotABareLink).
        let plist = try XCTUnwrap(NSDictionary(contentsOf: Self.infoPlistURL()))
        let rule = try XCTUnwrap(((plist["NSExtension"] as? NSDictionary)?["NSExtensionAttributes"] as? NSDictionary)?["NSExtensionActivationRule"] as? String)
        XCTAssertTrue(projectYML.contains("NSExtensionActivationRule: " + rule))
        XCTAssertFalse(infoPlist.isEmpty)
        XCTAssertFalse(Self.shareExtensionTargetBlock(in: projectYML)?.contains("Sources/ShareImport/ImporterServerURL.swift") ?? true)
        XCTAssertFalse(Self.shareExtensionTargetBlock(in: projectYML)?.contains("Sources/Transfer/") ?? true)
        XCTAssertFalse(Self.shareExtensionTargetBlock(in: projectYML)?.contains("ShareImportTransfer") ?? true)
    }

    private static func projectYMLURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
    }

    private static func infoPlistURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SolstoneShareExtension")
            .appendingPathComponent("Info.plist")
    }

    private static func shareExtensionTargetBlock(in projectYML: String) -> String? {
        guard let start = projectYML.range(of: "  SolstoneShareExtension:"),
              let end = projectYML[start.upperBound...].range(of: "  SolstoneLiveActivityWidget:")
        else {
            return nil
        }
        return String(projectYML[start.lowerBound..<end.lowerBound])
    }
}
