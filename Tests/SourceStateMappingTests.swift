// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SourceStateMappingTests: XCTestCase {
    func testObserverStatesMapToSourceStates() {
        XCTAssertEqual(sourceState(for: .idle, paused: false), .off)
        XCTAssertEqual(sourceState(for: .starting, paused: false), .enrolling)
        XCTAssertEqual(sourceState(for: .active(Self.session()), paused: false), .active)
        XCTAssertEqual(sourceState(for: .stopping, paused: false), .active)
        XCTAssertEqual(sourceState(for: .error(.permissionDenied), paused: false), .needsAttention)
        XCTAssertEqual(sourceState(for: .error(.diskFull), paused: false), .needsAttention)
        XCTAssertEqual(sourceState(for: .idle, paused: true), .paused)
    }

    func testImporterSourceStateMapping() {
        XCTAssertEqual(
            importerSourceState(shareState: AppGroupMirror.ShareSourceState(isActivated: false, isPaused: false), failedCount: 0),
            .off
        )
        XCTAssertEqual(
            importerSourceState(shareState: AppGroupMirror.ShareSourceState(isActivated: true, isPaused: false), failedCount: 0),
            .active
        )
        XCTAssertEqual(
            importerSourceState(shareState: AppGroupMirror.ShareSourceState(isActivated: true, isPaused: true), failedCount: 0),
            .paused
        )
        XCTAssertEqual(
            importerSourceState(shareState: AppGroupMirror.ShareSourceState(isActivated: true, isPaused: false), failedCount: 1),
            .needsAttention
        )
        XCTAssertEqual(
            importerSourceState(shareState: AppGroupMirror.ShareSourceState(isActivated: true, isPaused: true), failedCount: 1),
            .paused
        )
    }

    func testImporterActiveSubtextMapping() {
        XCTAssertEqual(importerActiveSubtext(pendingCount: 1, lastDeliveredAt: nil), SourceVocabulary.shareSendingProgress)
        XCTAssertEqual(importerActiveSubtext(pendingCount: 0, lastDeliveredAt: Date()), SourceVocabulary.shareDeliveredProgress)
        XCTAssertEqual(importerActiveSubtext(pendingCount: 0, lastDeliveredAt: nil), SourceVocabulary.importerActiveSubtext)
    }

    func testOnThisPhoneSendStateMapping() {
        XCTAssertEqual(onThisPhoneSendState(location: .delivered, isActivelyUploading: false), .inYourJournal)
        XCTAssertEqual(onThisPhoneSendState(location: .delivered, isActivelyUploading: true), .inYourJournal)
        XCTAssertEqual(onThisPhoneSendState(location: .failed, isActivelyUploading: false), .needsAttention)
        XCTAssertEqual(onThisPhoneSendState(location: .failed, isActivelyUploading: true), .needsAttention)
        XCTAssertEqual(onThisPhoneSendState(location: .pending, isActivelyUploading: true), .sending)
        XCTAssertEqual(onThisPhoneSendState(location: .pending, isActivelyUploading: false), .savedOnThisPhone)
    }

    func testOnThisPhoneSendStateLabels() {
        XCTAssertEqual(OnThisPhoneSendState.savedOnThisPhone.label, SourceVocabulary.sendStateSaved)
        XCTAssertEqual(OnThisPhoneSendState.sending.label, SourceVocabulary.sendStateSending)
        XCTAssertEqual(OnThisPhoneSendState.inYourJournal.label, SourceVocabulary.shareDeliveredProgress)
        XCTAssertEqual(OnThisPhoneSendState.needsAttention.label, SourceVocabulary.needsAttention)
    }

    private static func session() -> ObserverSession {
        ObserverSession(
            sessionID: UUID(),
            mode: .meeting,
            startedAt: Date(),
            currentChunkIndex: 0,
            elapsed: 0
        )
    }
}
