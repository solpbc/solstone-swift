// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

// criterion 10: build metadata uses real generated values.
@MainActor
final class IntegrationGateBuildMetadataTests: XCTestCase {
    func testAppVersionReportsResolvedSPLSwiftMetadata() throws {
        let resolved = try Self.resolvedSPLSwift()
        XCTAssertEqual(AppVersion.splSwiftIdentity, "spl-swift")
        XCTAssertEqual(AppVersion.splSwiftVersion, resolved.version)
        XCTAssertEqual(AppVersion.splSwiftRevision, resolved.revision)
        XCTAssertNotEqual(AppVersion.sourceCommit, "unknown")
        XCTAssertNotEqual(AppVersion.buildConfiguration, "unknown")
    }

    private static func resolvedSPLSwift() throws -> (version: String, revision: String) {
        let url = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("solstone-swift.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = try XCTUnwrap(object?["pins"] as? [[String: Any]])
        let pin = try XCTUnwrap(pins.first { $0["identity"] as? String == "spl-swift" })
        let state = try XCTUnwrap(pin["state"] as? [String: Any])
        return (
            try XCTUnwrap(state["version"] as? String),
            try XCTUnwrap(state["revision"] as? String)
        )
    }
}
