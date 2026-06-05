// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class LocationProjectConfigTests: XCTestCase {
    func testProjectYMLIncludesLocationUsageStringsAndBackgroundMode() throws {
        let projectYML = try String(contentsOf: Self.projectYMLURL(), encoding: .utf8)

        XCTAssertTrue(projectYML.contains(#"INFOPLIST_KEY_NSMicrophoneUsageDescription: "solstone listens to meetings and voice memos you start and keeps them on this phone — yours alone, until you connect a journal. nothing is shared with sol pbc.""#))
        XCTAssertTrue(projectYML.contains(#"INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: "solstone adds where your day happens and keeps it on this phone — yours alone, until you connect a journal. you choose how much; you can change it or delete it any time.""#))
        XCTAssertTrue(projectYML.contains(#"INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription: "solstone adds where your day happens, even in the background, and keeps it on this phone — yours alone, until you connect a journal. you choose how much; you can change it or delete it any time.""#))
        XCTAssertTrue(projectYML.contains("          - audio"))
        XCTAssertTrue(projectYML.contains("          - fetch"))
        XCTAssertTrue(projectYML.contains("          - location"))
        XCTAssertTrue(projectYML.contains("          - remote-notification"))
    }

    func testWidgetTargetIncludesOnlyLiveActivitySafeLocationSources() throws {
        let projectYML = try String(contentsOf: Self.projectYMLURL(), encoding: .utf8)
        let widgetBlock = try XCTUnwrap(Self.widgetTargetBlock(in: projectYML))

        for required in [
            "      - SolstoneLiveActivityWidget",
            "      - Sources/Observer/ObserverMode.swift",
            "      - Sources/Observer/ObserverLiveActivity.swift",
            "      - Sources/Design/Colors.swift",
            "      - Sources/Location/LocationLiveActivity.swift",
            "      - Sources/Location/LocationVocabulary.swift",
        ] {
            XCTAssertTrue(widgetBlock.contains(required), required)
        }

        for forbidden in [
            "Sources/Location/LocationManager.swift",
            "Sources/Location/LocationProviding.swift",
            "Sources/Location/LocationUploader.swift",
            "Sources/Location/LocationTier.swift",
        ] {
            XCTAssertFalse(widgetBlock.contains(forbidden), forbidden)
        }
    }

    func testProjectYMLRegistersSolstoneURLScheme() throws {
        let projectYML = try String(contentsOf: Self.projectYMLURL(), encoding: .utf8)
        let appBlock = try XCTUnwrap(Self.appTargetBlock(in: projectYML))

        for required in [
            "        CFBundleURLTypes:",
            "          - CFBundleURLName: app.solstone.swift",
            "            CFBundleURLSchemes:",
            "              - solstone",
        ] {
            XCTAssertTrue(appBlock.contains(required), required)
        }
    }

    private static func projectYMLURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
    }

    private static func widgetTargetBlock(in projectYML: String) -> String? {
        guard let start = projectYML.range(of: "  SolstoneLiveActivityWidget:"),
              let end = projectYML[start.upperBound...].range(of: "  solstone-swiftTests:")
        else {
            return nil
        }
        return String(projectYML[start.lowerBound..<end.lowerBound])
    }

    private static func appTargetBlock(in projectYML: String) -> String? {
        guard let start = projectYML.range(of: "  solstone-swift:"),
              let end = projectYML[start.upperBound...].range(of: "  SolstoneNotificationContent:")
        else {
            return nil
        }
        return String(projectYML[start.lowerBound..<end.lowerBound])
    }
}
