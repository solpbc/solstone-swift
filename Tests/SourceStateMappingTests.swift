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
        XCTAssertEqual(importerSourceState(failedCount: 0), .active)
        XCTAssertEqual(importerSourceState(failedCount: 1), .needsAttention)
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

    func testSourceVoiceOverTextIncludesStateLabels() {
        let activeSource = Source(
            id: "active",
            displayName: "audio",
            kind: .observer,
            group: .experiencingAlongsideYou,
            state: .active,
            activeSubtext: SourceVocabulary.observerActiveSubtext,
            attention: nil,
            pendingStatus: .nonePending
        )
        let needsAttentionSource = Source(
            id: "needs-attention",
            displayName: SourceVocabulary.shareSheetDisplayName,
            kind: .importer,
            group: .bringingInYourself,
            state: .needsAttention,
            activeSubtext: SourceVocabulary.importerActiveSubtext,
            attention: SourceAttention(message: SourceVocabulary.needsAttentionSubtext),
            pendingStatus: .nonePending
        )

        XCTAssertTrue(activeSource.voiceOverText.contains("on"))
        XCTAssertTrue(needsAttentionSource.voiceOverText.contains("needs attention"))
    }

    func testOnThisPhoneVoiceOverTextIncludesSendStateLabels() {
        let deliveredItem = Self.onThisPhoneItem(sendState: .inYourJournal)
        let failedItem = Self.onThisPhoneItem(sendState: .needsAttention)

        XCTAssertTrue(deliveredItem.voiceOverText.contains("saved to your journal"))
        XCTAssertTrue(failedItem.voiceOverText.contains("needs attention"))
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

    private static func onThisPhoneItem(sendState: OnThisPhoneSendState) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: UUID().uuidString,
            sourceKind: .share,
            sendState: sendState,
            contentType: "application/pdf",
            filename: "item.pdf",
            bytes: 42,
            originApp: "Files",
            basis: "share",
            itemTime: Date(),
            targetJournal: "journal",
            stream: "default",
            day: "2026-06-02",
            segment: "morning",
            deliveredAt: sendState == .inYourJournal ? Date() : nil,
            rawFileURL: nil
        )
    }
}
