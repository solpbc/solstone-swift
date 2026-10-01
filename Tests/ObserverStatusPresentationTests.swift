// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class ObserverStatusPresentationTests: XCTestCase {
    private func makeSnapshot(
        isPaired: Bool = true,
        sourceStates: [SourceKind: SourceState] = [.observer: .active],
        backlogCount: Int = 0,
        awaitingMarkConfirmation: Bool = false
    ) -> AppGroupMirror.Snapshot {
        AppGroupMirror.Snapshot(
            schemaVersion: AppGroupMirror.Snapshot.currentSchemaVersion,
            writtenAt: Date(),
            pairing: AppGroupMirror.PairingSnapshot(
                journalName: isPaired ? "sol" : nil,
                isPaired: isPaired
            ),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: sourceStates,
            backlogCount: backlogCount,
            awaitingMarkConfirmation: awaitingMarkConfirmation
        )
    }

    // MARK: - Small Widget

    func testSmallAwaitingMarkConfirmationWithBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 3, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: .observer)

        XCTAssertEqual(presentation, .awaitingMarkConfirmation(count: 3))
        XCTAssertEqual(presentation.count, 3)
        XCTAssertEqual(presentation.label, SourceVocabulary.confirmTheMarkAction)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.waiting(count: 1).symbol)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.caughtUp.symbol)
    }

    func testSmallAwaitingMarkConfirmationWithZeroBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 0, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: .observer)

        XCTAssertEqual(presentation, .awaitingMarkConfirmation(count: 0))
        XCTAssertNotEqual(presentation, .caughtUp)
        XCTAssertNil(presentation.count)
        XCTAssertEqual(presentation.label, SourceVocabulary.confirmTheMarkAction)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.waiting(count: 1).symbol)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.caughtUp.symbol)
    }

    func testSmallNotAwaitingWithBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 3, awaitingMarkConfirmation: false)
        let presentation = ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: .observer)

        XCTAssertEqual(presentation, .waiting(count: 3))
        XCTAssertEqual(presentation.count, 3)
    }

    func testSmallNotAwaitingWithZeroBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 0, awaitingMarkConfirmation: false)
        let presentation = ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: .observer)

        XCTAssertEqual(presentation, .caughtUp)
        XCTAssertNil(presentation.count)
    }

    func testSmallNotPairedWithAwaiting() {
        let snapshot = self.makeSnapshot(isPaired: false, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: .observer)

        XCTAssertEqual(presentation, .notPaired)
    }

    func testSmallUnavailableConditions() {
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: nil, sourceKind: .observer), .unavailable)

        let snapshot = self.makeSnapshot(sourceStates: [.observer: .active])
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: nil), .unavailable)
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: .location), .unavailable)

        let snapshotWithWatch = self.makeSnapshot(sourceStates: [.watch: .active])
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: snapshotWithWatch, sourceKind: .watch), .unavailable)
    }

    func testSmallNeedsAttentionPrecedenceOverAwaiting() {
        let snapshot = self.makeSnapshot(
            sourceStates: [.observer: .needsAttention],
            backlogCount: 2,
            awaitingMarkConfirmation: true
        )
        let presentation = ObserverStatusPresentations.small(snapshot: snapshot, sourceKind: .observer)

        XCTAssertEqual(presentation, .needsAttention)
    }

    // MARK: - Medium Widget

    func testMediumAwaitingMarkConfirmationWithBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 3, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.medium(snapshot: snapshot)

        XCTAssertEqual(presentation, .awaitingMarkConfirmation(count: 3))
        XCTAssertEqual(presentation.count, 3)
        XCTAssertEqual(presentation.label, SourceVocabulary.confirmTheMarkAction)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.waiting(count: 1).symbol)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.caughtUp.symbol)
    }

    func testMediumAwaitingMarkConfirmationWithZeroBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 0, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.medium(snapshot: snapshot)

        XCTAssertEqual(presentation, .awaitingMarkConfirmation(count: 0))
        XCTAssertNotEqual(presentation, .caughtUp)
        XCTAssertNil(presentation.count)
        XCTAssertEqual(presentation.label, SourceVocabulary.confirmTheMarkAction)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.waiting(count: 1).symbol)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.caughtUp.symbol)
    }

    func testMediumNotAwaitingWithBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 3, awaitingMarkConfirmation: false)
        let presentation = ObserverStatusPresentations.medium(snapshot: snapshot)

        XCTAssertEqual(presentation, .waiting(count: 3))
        XCTAssertEqual(presentation.count, 3)
    }

    func testMediumNotAwaitingWithZeroBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 0, awaitingMarkConfirmation: false)
        let presentation = ObserverStatusPresentations.medium(snapshot: snapshot)

        XCTAssertEqual(presentation, .caughtUp)
        XCTAssertNil(presentation.count)
    }

    func testMediumNotPairedWithAwaiting() {
        let snapshot = self.makeSnapshot(isPaired: false, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.medium(snapshot: snapshot)

        XCTAssertEqual(presentation, .notPaired)
    }

    func testMediumNilSnapshotUnavailable() {
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: nil), .unavailable)
    }

    func testMediumNeedsAttentionPrecedenceOverAwaiting() {
        let snapshot = self.makeSnapshot(
            sourceStates: [.observer: .active, .location: .needsAttention],
            backlogCount: 2,
            awaitingMarkConfirmation: true
        )
        let presentation = ObserverStatusPresentations.medium(snapshot: snapshot)

        XCTAssertEqual(presentation, .needsAttention)
    }

    // MARK: - Circular Widget

    func testCircularAwaitingMarkConfirmationWithBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 3, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.circular(snapshot: snapshot)

        XCTAssertEqual(presentation, .awaitingMarkConfirmation(count: 3))
        XCTAssertEqual(presentation.count, 3)
        XCTAssertEqual(presentation.label, SourceVocabulary.confirmTheMarkAction)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.waiting(count: 1).symbol)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.caughtUp.symbol)
    }

    func testCircularAwaitingMarkConfirmationWithZeroBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 0, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.circular(snapshot: snapshot)

        XCTAssertEqual(presentation, .awaitingMarkConfirmation(count: 0))
        XCTAssertNotEqual(presentation, .caughtUp)
        XCTAssertNil(presentation.count)
        XCTAssertEqual(presentation.label, SourceVocabulary.confirmTheMarkAction)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.waiting(count: 1).symbol)
        XCTAssertNotEqual(presentation.symbol, ObserverStatusPresentation.caughtUp.symbol)
    }

    func testCircularNotAwaitingWithBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 3, awaitingMarkConfirmation: false)
        let presentation = ObserverStatusPresentations.circular(snapshot: snapshot)

        XCTAssertEqual(presentation, .waiting(count: 3))
        XCTAssertEqual(presentation.count, 3)
    }

    func testCircularNotAwaitingWithZeroBacklog() {
        let snapshot = self.makeSnapshot(backlogCount: 0, awaitingMarkConfirmation: false)
        let presentation = ObserverStatusPresentations.circular(snapshot: snapshot)

        XCTAssertEqual(presentation, .caughtUp)
        XCTAssertNil(presentation.count)
    }

    func testCircularNotPairedWithAwaiting() {
        let snapshot = self.makeSnapshot(isPaired: false, awaitingMarkConfirmation: true)
        let presentation = ObserverStatusPresentations.circular(snapshot: snapshot)

        XCTAssertEqual(presentation, .notPaired)
    }

    func testCircularNilSnapshotUnavailable() {
        XCTAssertEqual(ObserverStatusPresentations.circular(snapshot: nil), .unavailable)
    }

    func testCircularSourceNeedsAttentionYieldsAwaiting() {
        let snapshot = self.makeSnapshot(
            sourceStates: [.observer: .needsAttention],
            backlogCount: 2,
            awaitingMarkConfirmation: true
        )
        let presentation = ObserverStatusPresentations.circular(snapshot: snapshot)

        XCTAssertEqual(presentation, .awaitingMarkConfirmation(count: 2))
        XCTAssertNotEqual(presentation, .needsAttention)
    }
}
