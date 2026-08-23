// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastSourceUITests: XCTestCase {
    func testScreencastSourcePresentationIsExperiencingAlongsideYou() {
        let source = screencastSourcePresentation(managerState: .off, isJournalPaired: true)

        XCTAssertEqual(source.id, "screencast")
        XCTAssertEqual(source.displayName, SourceVocabulary.screencastDisplayName)
        XCTAssertEqual(source.kind, .screencast)
        XCTAssertEqual(source.subtext, SourceVocabulary.screencastOffSubtext)
    }

    func testScreencastRowIsPlacedAfterLocationBeforeOmi() throws {
        let rows = SourcesViewRowBuilder.addMoreRows(
            audio: Self.source(id: "audio", kind: .observer),
            location: Self.source(id: "location", kind: .location),
            screencast: Self.source(id: "screen", kind: .screencast),
            omi: Self.source(id: "omi", kind: .omi),
            watch: Self.source(id: "watch", kind: .watch),
            hiddenIDs: []
        )
        let routes = rows.map(\.route)
        let locationIndex = try XCTUnwrap(routes.firstIndex(of: .location))
        let screencastIndex = try XCTUnwrap(routes.firstIndex(of: .screencast))
        let omiIndex = try XCTUnwrap(routes.firstIndex(of: .omi))

        XCTAssertLessThan(locationIndex, screencastIndex)
        XCTAssertLessThan(screencastIndex, omiIndex)
    }

    func testScreencastPresentationMapsManagerStates() {
        XCTAssertEqual(screencastSourcePresentation(managerState: .off, isJournalPaired: true).state, .off)
        XCTAssertEqual(
            screencastSourcePresentation(
                managerState: .starting(startedAt: Date(timeIntervalSince1970: 1), deadline: Date(timeIntervalSince1970: 21)),
                isJournalPaired: true
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
                isJournalPaired: true
            ).state,
            .active
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .needsAttention(.finalizeFailed), isJournalPaired: true).state,
            .needsAttention
        )
        XCTAssertEqual(
            screencastSourcePresentation(managerState: .unavailable(.extensionUnavailable), isJournalPaired: true).state,
            .needsAttention
        )
    }

    func testScreencastBacklogNeverDrivesNeedsAttention() {
        let offSource = screencastSourcePresentation(managerState: .off, isJournalPaired: true)
        XCTAssertNil(offSource.attention)
        XCTAssertNotEqual(offSource.state, .needsAttention)

        let activeSource = screencastSourcePresentation(
            managerState: .active(
                sessionID: UUID(),
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1)
            ),
            isJournalPaired: true
        )
        XCTAssertNil(activeSource.attention)

        let faultSource = screencastSourcePresentation(managerState: .needsAttention(.finalizeFailed), isJournalPaired: true)
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
