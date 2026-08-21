// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class LinkedDeviceIngestReconciliationWiringGrepTests: XCTestCase {
    func testDetailViewsDelegateRecentReconciliationWithoutEmptyFallbacks() throws {
        let audio = try Self.sourceText("Sources/SourceDetailView.swift")
        let location = try Self.sourceText("Sources/Location/LocationSourceDetailView.swift")
        let audioLoadBody = try Self.slice(
            in: audio,
            from: "func loadManifest() async {",
            to: "private struct AudioEnrollmentContent"
        )
        let locationLoadBody = try Self.slice(
            in: location,
            from: "func loadRecent() async {",
            to: "private struct LocationEnrollmentContent"
        )

        XCTAssertTrue(audio.contains("LinkedDeviceIngestReconciler"))
        XCTAssertTrue(location.contains("LinkedDeviceIngestReconciler"))
        XCTAssertTrue(audioLoadBody.contains("await reconciler.reconcileObserverManifest("))
        XCTAssertTrue(locationLoadBody.contains("await reconciler.reconcileLocationRecent("))
        XCTAssertTrue(audio.contains("@State private var manifestResult: ObserverManifestResult?"))
        XCTAssertTrue(audio.contains("case .none:\n            ProgressView()"))
        XCTAssertTrue(audioLoadBody.contains("self.manifestResult = nil"))
        XCTAssertFalse(audio.contains("self.manifestResult = .loadedEmpty"))
        XCTAssertFalse(location.contains("self.recentResult = .loadedEmpty"))
        XCTAssertFalse(audioLoadBody.contains("ensureRegistered"))
        XCTAssertFalse(locationLoadBody.contains("ensureRegistered"))
    }
}

private extension LinkedDeviceIngestReconciliationWiringGrepTests {
    static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
