// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastSourceUITests: XCTestCase {
    func testScreencastSourcePresentationIsExperiencingAlongsideYou() {
        let source = screencastSourcePresentation(managerState: .off, isJournalPaired: true, enrolled: true)

        XCTAssertEqual(source.id, "screencast")
        XCTAssertEqual(source.displayName, SourceVocabulary.screencastDisplayName)
        XCTAssertEqual(source.kind, .screencast)
        XCTAssertEqual(source.subtext, SourceVocabulary.screencastOffSubtext)
    }

    func testScreencastRowIsPlacedAfterLocationBeforeWatch() throws {
        let rows = SourcesViewRowBuilder.addMoreRows(
            audio: Self.source(id: "audio", kind: .observer),
            location: Self.source(id: "location", kind: .location),
            screencast: Self.source(id: "screen", kind: .screencast),
            watch: Self.source(id: "watch", kind: .watch),
            hiddenIDs: []
        )
        let routes = rows.map(\.route)
        let locationIndex = try XCTUnwrap(routes.firstIndex(of: .location))
        let screencastIndex = try XCTUnwrap(routes.firstIndex(of: .screencast))
        let watchIndex = try XCTUnwrap(routes.firstIndex(of: .watch))

        XCTAssertLessThan(locationIndex, screencastIndex)
        XCTAssertLessThan(screencastIndex, watchIndex)
    }

    func testScreencastPresentationMapsManagerStates() {
        XCTAssertEqual(screencastSourcePresentation(managerState: .off, isJournalPaired: true, enrolled: true).state, .off)
        XCTAssertEqual(
            screencastSourcePresentation(
                managerState: .starting(startedAt: Date(timeIntervalSince1970: 1), deadline: Date(timeIntervalSince1970: 21)),
                isJournalPaired: true,
                enrolled: true
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
                isJournalPaired: true,
                enrolled: true
            ).state,
            .active
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .needsAttention(.finalizeFailed), isJournalPaired: true, enrolled: true).state,
            .needsAttention
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .unavailable(.extensionUnavailable), isJournalPaired: true, enrolled: true).state,
            .needsAttention
        )
    }

    func testScreencastBacklogNeverDrivesNeedsAttention() {
        let offSource = screencastSourcePresentation(managerState: .off, isJournalPaired: true, enrolled: true)
        XCTAssertNil(offSource.attention)
        XCTAssertNotEqual(offSource.state, .needsAttention)

        let activeSource = screencastSourcePresentation(
            managerState: .active(
                sessionID: UUID(),
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1)
            ),
            isJournalPaired: true,
                enrolled: true
        )
        XCTAssertNil(activeSource.attention)

        let faultSource = screencastSourcePresentation(managerState: .needsAttention(.finalizeFailed), isJournalPaired: true, enrolled: true)
        XCTAssertEqual(faultSource.state, .needsAttention)
        XCTAssertEqual(faultSource.attention?.message, screencastAttentionMessage(.finalizeFailed))
    }

    private static func source(id: String, kind: SourceKind) -> Source {
        Source(
            id: id,
            displayName: id,
            kind: kind,
            state: .off,
            isJournalPaired: true,
            activeSubtext: "on",
            attention: nil,
            pendingStatus: .nonePending
        )
    }
}
