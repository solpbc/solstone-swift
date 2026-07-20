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

    func testOnThisPhoneSendStateMapping() {
        XCTAssertEqual(onThisPhoneSendState(location: .delivered, canRetry: false, isActivelyUploading: false), .inYourJournal)
        XCTAssertEqual(onThisPhoneSendState(location: .delivered, canRetry: true, isActivelyUploading: true), .inYourJournal)
        XCTAssertEqual(onThisPhoneSendState(location: .failed, canRetry: true, isActivelyUploading: false), .savedOnThisPhone)
        XCTAssertEqual(onThisPhoneSendState(location: .failed, canRetry: false, isActivelyUploading: true), .needsAttention)
        XCTAssertEqual(onThisPhoneSendState(location: .pending, canRetry: false, isActivelyUploading: true), .sending)
        XCTAssertEqual(onThisPhoneSendState(location: .pending, canRetry: false, isActivelyUploading: false), .savedOnThisPhone)
    }

    func testFailureDetailDoesNotChangeOnThisPhoneSendState() {
        let failedAudio = OnThisPhoneItem(
            id: "audio:\(UUID().uuidString):chunk",
            sourceKind: .audio,
            sendState: onThisPhoneSendState(location: .failed, canRetry: false, isActivelyUploading: false),
            contentType: "audio/mp4",
            filename: "chunk.m4a",
            bytes: 42,
            originApp: nil,
            basis: nil,
            itemTime: Date(),
            targetJournal: nil,
            stream: nil,
            day: "20260602",
            segment: "120000_300",
            deliveredAt: nil,
            rawFileURL: nil,
            audioDurationS: 3,
            failureReason: "journal rejected the upload (HTTP 503)",
            failureAttemptCount: 5,
            sourceLabel: SourceVocabulary.onThisPhoneObserverAudioSourceLabel,
            retryAvailable: true
        )

        XCTAssertEqual(failedAudio.sendState, .needsAttention)
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
            isJournalPaired: true,
            activeSubtext: SourceVocabulary.observerActiveSubtext,
            attention: nil,
            pendingStatus: .nonePending,
            detailSubtext: "battery 87% as of 12m ago"
        )
        let needsAttentionSource = Source(
            id: "needs-attention",
            displayName: SourceVocabulary.shareSheetDisplayName,
            kind: .importer,
            group: .bringingInYourself,
            state: .needsAttention,
            isJournalPaired: true,
            activeSubtext: SourceVocabulary.shareAlwaysOnSubtext(isJournalPaired: true),
            attention: SourceAttention(message: SourceVocabulary.needsAttentionSubtext),
            pendingStatus: .nonePending
        )
        let watchIdleSource = Source(
            id: "watch",
            displayName: SourceVocabulary.watchSourceDisplayName,
            kind: .watch,
            group: .experiencingAlongsideYou,
            state: .off,
            isJournalPaired: true,
            activeSubtext: SourceVocabulary.watchListeningSubtext,
            subtextOverride: SourceVocabulary.watchIdleNowSubtext,
            attention: nil,
            pendingStatus: .nonePending
        )
        let checkingSource = Source(
            id: "watch-checking",
            displayName: SourceVocabulary.watchSourceDisplayName,
            kind: .watch,
            group: .experiencingAlongsideYou,
            state: .checking,
            isJournalPaired: true,
            activeSubtext: SourceVocabulary.watchListeningSubtext,
            attention: nil,
            pendingStatus: .nonePending,
            showsSubtext: false
        )

        XCTAssertTrue(activeSource.voiceOverText.contains("on"))
        XCTAssertTrue(activeSource.voiceOverText.contains("battery 87% as of 12m ago"))
        XCTAssertTrue(needsAttentionSource.voiceOverText.contains("needs attention"))
        XCTAssertEqual(watchIdleSource.subtext, SourceVocabulary.watchIdleNowSubtext)
        XCTAssertTrue(watchIdleSource.voiceOverText.contains(SourceVocabulary.watchIdleNowSubtext))
        XCTAssertNil(checkingSource.rowSubtext)
        XCTAssertEqual(checkingSource.voiceOverText, SourceVocabulary.sourceStateCheckingLabel)
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
