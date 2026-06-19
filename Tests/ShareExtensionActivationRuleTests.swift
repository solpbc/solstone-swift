// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ShareExtensionActivationRuleTests: XCTestCase {
    func testPlainTextActivationRuleIsPresentInProjectAndPlist() throws {
        let projectYML = try String(contentsOf: Self.projectYMLURL(), encoding: .utf8)
        let infoPlist = try String(contentsOf: Self.infoPlistURL(), encoding: .utf8)
        let plainTextPredicate = #"ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.plain-text""#

        XCTAssertTrue(projectYML.contains(plainTextPredicate))
        XCTAssertTrue(infoPlist.contains(plainTextPredicate))
        XCTAssertTrue(projectYML.contains("Sources/ImportQueue/ImporterServerURL.swift"))
        XCTAssertFalse(Self.shareExtensionTargetBlock(in: projectYML)?.contains("Sources/Observer/ObserverAuthorizedRequest.swift") ?? true)
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
