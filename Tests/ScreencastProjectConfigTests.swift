// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ScreencastProjectConfigTests: XCTestCase {
    func testBroadcastTargetDeclaresUploadExtensionPoint() throws {
        let block = try Self.broadcastTargetBlock()

        XCTAssertTrue(block.contains("NSExtensionPointIdentifier: com.apple.broadcast-services-upload"))
    }

    func testBroadcastTargetUsesSampleBufferProcessMode() throws {
        let block = try Self.broadcastTargetBlock()

        XCTAssertTrue(block.contains("          RPBroadcastProcessMode: RPBroadcastProcessModeSampleBuffer"))
        XCTAssertFalse(block.contains("NSExtensionAttributes"))
    }

    func testBroadcastTargetUsesSampleHandlerPrincipalClass() throws {
        let block = try Self.broadcastTargetBlock()

        XCTAssertTrue(block.contains("NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).SampleHandler"))
    }

    func testBroadcastTargetUsesAppGroupEntitlementOnly() throws {
        let block = try Self.broadcastTargetBlock()

        XCTAssertTrue(block.contains("path: SolstoneBroadcastExtension/SolstoneBroadcastExtension.entitlements"))
        XCTAssertTrue(block.contains("com.apple.security.application-groups:"))
        XCTAssertTrue(block.contains("- group.app.solstone.swift"))
        XCTAssertFalse(block.contains("aps-environment"))
        XCTAssertFalse(block.contains("com.apple.developer.associated-domains"))
    }

    func testAppEmbedsBroadcastExtension() throws {
        let appBlock = try Self.appTargetBlock()

        XCTAssertTrue(appBlock.contains("- target: SolstoneBroadcastExtension"))
        XCTAssertTrue(appBlock.contains("embed: true"))
    }

    func testBroadcastTargetIncludesRequiredSharedFiles() throws {
        let block = try Self.broadcastTargetBlock()

        for required in [
            "- path: SolstoneBroadcastExtension",
            "- path: Sources/Services/AppGroupContainer.swift",
            "- path: Sources/MobileSegment/MobileSegmentModels.swift",
            "- path: Sources/Observer/ObserverMode.swift",
            "- path: Sources/MobileSegment/MobileSegmentScreencastShared.swift",
        ] {
            XCTAssertTrue(block.contains(required), required)
        }
    }

    func testBroadcastTargetExcludesAppOnlySourcesAndDependencies() throws {
        let block = try Self.broadcastTargetBlock()

        for forbidden in [
            "Sources/MobileSegment/MobileSegmentStore.swift",
            "Sources/MobileSegment/MobileSegmentUploader.swift",
            "Sources/MobileSegment/MobileSegmentEngine.swift",
            "ObserverUploader.swift",
            "Sources/Tunnel",
            "swift-nio",
            "SwiftUI",
            "Observation",
            "Crypto",
        ] {
            XCTAssertFalse(block.contains(forbidden), forbidden)
        }
    }

    func testBroadcastTargetPinsBundleIDTeamVersionAndStrictConcurrency() throws {
        let block = try Self.broadcastTargetBlock()

        for required in [
            "type: app-extension",
            #"deploymentTarget: "26.0""#,
            "PRODUCT_BUNDLE_IDENTIFIER: app.solstone.swift.broadcast",
            "INFOPLIST_KEY_CFBundleDisplayName: screen",
            "CFBundleDisplayName: screen",
            "CFBundleShortVersionString: $(MARKETING_VERSION)",
            "CFBundleVersion: $(CURRENT_PROJECT_VERSION)",
            "DEVELOPMENT_TEAM: 7QCG8V4M6H",
            #"MARKETING_VERSION: "0.1.0""#,
            "SWIFT_STRICT_CONCURRENCY: complete",
            #"SWIFT_VERSION: "6.0""#,
        ] {
            XCTAssertTrue(block.contains(required), required)
        }

        let appVersion = Self.parseCurrentProjectVersion(in: try Self.baseSettingsBlock())
        let broadcastVersion = Self.parseCurrentProjectVersion(in: block)

        XCTAssertNotNil(appVersion, "app CURRENT_PROJECT_VERSION present")
        XCTAssertNotNil(broadcastVersion, "broadcast CURRENT_PROJECT_VERSION present")
        XCTAssertEqual(
            appVersion,
            broadcastVersion,
            "app and broadcast must share the same build number"
        )
    }
}

private extension ScreencastProjectConfigTests {
    static func projectYML() throws -> String {
        try String(contentsOf: self.projectYMLURL(), encoding: .utf8)
    }

    static func projectYMLURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
    }

    static func broadcastTargetBlock() throws -> String {
        let projectYML = try self.projectYML()
        guard let start = projectYML.range(of: "  SolstoneBroadcastExtension:"),
              let end = projectYML[start.upperBound...].range(of: "  SolstoneLiveActivityWidget:")
        else {
            throw XCTSkip("SolstoneBroadcastExtension block missing")
        }
        return String(projectYML[start.lowerBound..<end.lowerBound])
    }

    static func baseSettingsBlock() throws -> String {
        let projectYML = try self.projectYML()
        guard let start = projectYML.range(of: "settings:"),
              let end = projectYML[start.upperBound...].range(of: "packages:")
        else {
            throw XCTSkip("base settings block missing")
        }
        return String(projectYML[start.lowerBound..<end.lowerBound])
    }

    static func parseCurrentProjectVersion(in region: String) -> Int? {
        let pattern = #"(?m)^\s*CURRENT_PROJECT_VERSION:\s*([0-9]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(region.startIndex..<region.endIndex, in: region)
        guard let match = regex.firstMatch(in: region, range: range),
              let versionRange = Range(match.range(at: 1), in: region)
        else {
            return nil
        }
        return Int(region[versionRange])
    }

    static func appTargetBlock() throws -> String {
        let projectYML = try self.projectYML()
        guard let start = projectYML.range(of: "  solstone-swift:"),
              let end = projectYML[start.upperBound...].range(of: "  SolstoneNotificationContent:")
        else {
            throw XCTSkip("solstone-swift block missing")
        }
        return String(projectYML[start.lowerBound..<end.lowerBound])
    }
}
