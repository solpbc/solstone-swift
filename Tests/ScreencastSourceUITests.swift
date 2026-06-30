// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastSourceUITests: XCTestCase {
    func testScreencastSourcePresentationIsExperiencingAlongsideYou() {
        let source = screencastSourcePresentation(managerState: .off)

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
        XCTAssertEqual(screencastSourcePresentation(managerState: .off).state, .off)
        XCTAssertEqual(
            screencastSourcePresentation(
                managerState: .starting(startedAt: Date(timeIntervalSince1970: 1), deadline: Date(timeIntervalSince1970: 21))
            ).state,
            .enrolling
        )
        XCTAssertEqual(
            screencastSourcePresentation(
                managerState: .active(
                    sessionID: UUID(),
                    segmentID: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1)
                )
            ).state,
            .active
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .needsAttention(.finalizeFailed)).state,
            .needsAttention
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .unavailable(.extensionUnavailable)).state,
            .needsAttention
        )
    }

    func testScreencastBacklogNeverDrivesNeedsAttention() {
        let offSource = screencastSourcePresentation(managerState: .off)
        XCTAssertNil(offSource.attention)
        XCTAssertNotEqual(offSource.state, .needsAttention)

        let activeSource = screencastSourcePresentation(
            managerState: .active(
                sessionID: UUID(),
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1)
            )
        )
        XCTAssertNil(activeSource.attention)

        let faultSource = screencastSourcePresentation(managerState: .needsAttention(.finalizeFailed))
        XCTAssertEqual(faultSource.state, .needsAttention)
        XCTAssertEqual(faultSource.attention?.message, screencastAttentionMessage(.finalizeFailed))
    }

    private static func sourcesViewURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SourcesView.swift")
    }
}
