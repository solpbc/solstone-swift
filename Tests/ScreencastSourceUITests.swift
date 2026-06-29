// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastSourceUITests: XCTestCase {
    func testScreencastSourcePresentationIsExperiencingAlongsideYou() {
        let source = screencastSourcePresentation(
            managerState: .off,
            summary: MobileSegmentSourceSummary(
                pendingCount: 0,
                failedCount: 0,
                lastUploadAt: nil,
                lastError: nil
            )
        )

        XCTAssertEqual(source.id, "screencast")
        XCTAssertEqual(source.displayName, SourceVocabulary.screencastDisplayName)
        XCTAssertEqual(source.kind, .screencast)
        XCTAssertEqual(source.group, .experiencingAlongsideYou)
        XCTAssertEqual(source.subtext, SourceVocabulary.screencastOffSubtext)
    }

    func testScreencastRowIsPlacedAfterLocationBeforeOmi() throws {
        let sourcesView = try String(contentsOf: Self.sourcesViewURL(), encoding: .utf8)
        let locationRange = try XCTUnwrap(sourcesView.range(of: "SourceRowView(source: self.locationSource)"))
        let screencastRange = try XCTUnwrap(sourcesView.range(of: "SourceRowView(source: self.screencastSource)"))
        let omiRange = try XCTUnwrap(sourcesView.range(of: "SourceRowView(source: self.omiSource)"))

        XCTAssertLessThan(locationRange.lowerBound, screencastRange.lowerBound)
        XCTAssertLessThan(screencastRange.lowerBound, omiRange.lowerBound)
    }

    func testScreencastPresentationMapsManagerStates() {
        let summary = MobileSegmentSourceSummary(
            pendingCount: 0,
            failedCount: 0,
            lastUploadAt: nil,
            lastError: nil
        )

        XCTAssertEqual(screencastSourcePresentation(managerState: .off, summary: summary).state, .off)
        XCTAssertEqual(
            screencastSourcePresentation(
                managerState: .starting(startedAt: Date(timeIntervalSince1970: 1), deadline: Date(timeIntervalSince1970: 21)),
                summary: summary
            ).state,
            .enrolling
        )
        XCTAssertEqual(
            screencastSourcePresentation(
                managerState: .active(
                    sessionID: UUID(),
                    segmentID: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1)
                ),
                summary: summary
            ).state,
            .active
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .needsAttention(.finalizeFailed), summary: summary).state,
            .needsAttention
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .unavailable(.extensionUnavailable), summary: summary).state,
            .needsAttention
        )
    }

    private static func sourcesViewURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SourcesView.swift")
    }
}
