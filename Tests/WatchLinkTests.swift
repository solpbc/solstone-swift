// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class WatchLinkTests: XCTestCase {
    @MainActor private lazy var session = MockWatchConnectivitySession()

    @MainActor
    func testWatchStateIsSurfacedAtInit() {
        self.session.isSupported = true
        self.session.isPaired = true
        self.session.isWatchAppInstalled = true
        self.session.activationState = .activated

        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())

        XCTAssertTrue(watchLink.isSupported)
        XCTAssertTrue(watchLink.isPaired)
        XCTAssertTrue(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .activated)
    }

    @MainActor
    func testActivateInvokesSessionActivation() async {
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())

        watchLink.activate()
        await self.yieldToMainActor()

        XCTAssertEqual(self.session.activateCallCount, 1)
    }

    @MainActor
    func testActivationRefreshesWatchState() async {
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())

        watchLink.activate()
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.activationState, .activated)
    }

    @MainActor
    func testReachabilityTransitionIsSurfaced() async {
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())
        XCTAssertEqual(watchLink.isReachable, false)

        self.session.emitReachability(true)
        await self.yieldToMainActor()
        XCTAssertEqual(watchLink.isReachable, true)

        self.session.emitReachability(false)
        await self.yieldToMainActor()
        XCTAssertEqual(watchLink.isReachable, false)
    }

    @MainActor
    func testWatchStateTransitionIsSurfaced() async {
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())
        XCTAssertFalse(watchLink.isPaired)
        XCTAssertFalse(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .notActivated)

        self.session.emitWatchState(
            isPaired: true,
            isWatchAppInstalled: true,
            activationState: .activated
        )
        await self.yieldToMainActor()

        XCTAssertTrue(watchLink.isPaired)
        XCTAssertTrue(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .activated)

        self.session.emitWatchState(
            isPaired: true,
            isWatchAppInstalled: false,
            activationState: .inactive
        )
        await self.yieldToMainActor()

        XCTAssertTrue(watchLink.isPaired)
        XCTAssertFalse(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .inactive)
    }

    @MainActor
    func testDeliveredApplicationContextUpdatesWatchStatus() async {
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())
        let status = Self.status(seq: 1)

        self.session.deliverApplicationContext(status.applicationContext())
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.watchStatus, status)
    }

    @MainActor
    func testDeliveredApplicationContextMergesTerminalHistoryAndExportsIt() async throws {
        let store = Self.historyStore()
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: store)
        let now = Date()
        let entry = Self.historyEntry(now: now)
        let payload = Self.historyPayload(entries: [entry])
        let envelope = WatchRelayDiagnosticsEnvelope(
            generatedAt: now,
            diagnostics: .available(payload)
        )
        let data = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(envelope)
        let status = WatchStatusContext(
            phase: .idle,
            sessionID: nil,
            startedAt: nil,
            asOf: now,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0,
            diagnosticsEnvelope: data
        )

        self.session.deliverApplicationContext(status.applicationContext())
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.watchStatus?.seq, status.seq)
        let rawSnapshot = store.readSnapshot(asOf: now)
        let phoneHistory = WatchPipelineInputReader.phoneSessionHistoryInput(from: rawSnapshot)
        let export = WatchPipelineReducer.reduce(Self.pipelineInput(phoneSessionHistory: phoneHistory)).diagnosticsExportText
        XCTAssertTrue(export.contains("outcome: audio-clock-stalled / detected-stopped-itself"))
        XCTAssertTrue(export.contains("wrist alert: schedule / delivered yes"))
    }

    @MainActor
    func testActivateRecoversReceivedApplicationContext() async {
        let status = Self.status(seq: 2)
        self.session.receivedApplicationContext = status.applicationContext()
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())

        watchLink.activate()
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.watchStatus, status)
        XCTAssertEqual(
            watchRecordingStatus(
                context: watchLink.watchStatus,
                now: Date(timeIntervalSince1970: 1_020),
                lastReceivedAt: nil
            ),
            .observing
        )
    }

    @MainActor
    func testReachabilityDoesNotAffectWatchStatus() async {
        let status = Self.status(seq: 3)
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore())
        self.session.deliverApplicationContext(status.applicationContext())
        await self.yieldToMainActor()

        self.session.emitReachability(true)
        await self.yieldToMainActor()
        self.session.emitReachability(false)
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.watchStatus, status)
    }

    @MainActor
    func testReachabilityCannotMakeMissingContextObserving() {
        self.session.isSupported = true
        self.session.isPaired = true
        self.session.isWatchAppInstalled = true
        self.session.activationState = .activated
        self.session.isReachable = true
        let facts = WatchSourceFacts(defaults: Self.defaults())
        facts.noteStatusContextCheckedIn()
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: facts, phoneSessionHistoryStore: Self.historyStore())

        let recordingStatus = watchRecordingStatus(
            context: watchLink.watchStatus,
            now: Date(timeIntervalSince1970: 1_020),
            lastReceivedAt: nil
        )
        let readiness = watchSessionReadiness(
            isSupported: watchLink.isSupported,
            activationState: watchLink.activationState,
            activationFailed: watchLink.activationFailed
        ) {
            watchActivatedReadiness(
                isPaired: watchLink.isPaired,
                isWatchAppInstalled: watchLink.isWatchAppInstalled,
                facts: facts.snapshot
            )
        }
        let presentation = phoneWatchSourcePresentation(
            lane: phoneWatchSourceLane(
                session: readiness,
                flow: WatchInstalledFlowInput(
                    stuck: .none,
                    recordingStatus: recordingStatus,
                    waiting: WatchPipelineReducer.waitingBreakdown(Self.pipelineInput())
                )
            )
        )

        XCTAssertEqual(recordingStatus, .noContext)
        XCTAssertEqual(presentation.state, .off)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchStatusUnknownSubtext)
        XCTAssertEqual(presentation.statusReason, SourceVocabulary.watchStatusUnknownReason)
    }

    @MainActor
    func testWatchAppInstalledFlipRecomputesInstalledNeverOpenedWithoutRelaunch() async {
        self.session.isSupported = true
        self.session.isPaired = true
        self.session.isWatchAppInstalled = false
        self.session.activationState = .activated
        let facts = WatchSourceFacts(defaults: Self.defaults())
        let watchLink = WatchLink(session: self.session, receiver: nil, facts: facts, phoneSessionHistoryStore: Self.historyStore())

        XCTAssertEqual(Self.readiness(link: watchLink, facts: facts), .activated(.readyToSetUp(.installApp)))

        self.session.emitWatchState(isPaired: true, isWatchAppInstalled: true, activationState: .activated)
        await self.yieldToMainActor()

        XCTAssertEqual(Self.readiness(link: watchLink, facts: facts), .activated(.installedNeverOpened))
    }

    @MainActor
    func testACKQueueSnapshotClassifiesOutstandingUserInfoTransfersAndConservesCounts() {
        let duplicatedID = UUID()
        let singleID = UUID()
        self.session.seedOutstandingUserInfoTransfer(recognizedType: .watchSegmentACK, segmentID: duplicatedID)
        self.session.seedOutstandingUserInfoTransfer(recognizedType: .watchSegmentACK, segmentID: duplicatedID)
        self.session.seedOutstandingUserInfoTransfer(recognizedType: .watchSegmentACK, segmentID: singleID)
        self.session.seedOutstandingUserInfoTransfer(recognizedType: .watchSegmentACK, idState: .missing)
        self.session.seedOutstandingUserInfoTransfer(recognizedType: .watchSegmentACK, idState: .unparseable)
        self.session.seedOutstandingUserInfoTransfer(recognizedType: nil)

        let snapshot = WatchLink(session: self.session, receiver: nil, facts: Self.facts(), phoneSessionHistoryStore: Self.historyStore()).iPhoneACKQueueSnapshot

        XCTAssertEqual(snapshot.total, 6)
        XCTAssertEqual(snapshot.recognizedACK, 5)
        XCTAssertEqual(snapshot.parseableACK, 3)
        XCTAssertEqual(snapshot.distinctIdentities, 2)
        XCTAssertEqual(snapshot.duplicateExtras, 1)
        XCTAssertEqual(snapshot.malformedOrMissing, 2)
        XCTAssertEqual(snapshot.nonACK, 1)
        XCTAssertEqual(snapshot.identityCounts[duplicatedID], 2)
        XCTAssertEqual(snapshot.identityCounts[singleID], 1)
        XCTAssertTrue(snapshot.hasConsistentCounts)
        XCTAssertEqual(snapshot.total, snapshot.recognizedACK + snapshot.nonACK)
        XCTAssertEqual(snapshot.recognizedACK, snapshot.parseableACK + snapshot.malformedOrMissing)
        XCTAssertEqual(snapshot.parseableACK, snapshot.distinctIdentities + snapshot.duplicateExtras)
    }

    @MainActor
    private func yieldToMainActor() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    @MainActor
    private static func readiness(link: WatchLink, facts: WatchSourceFacts) -> WatchSessionReadiness {
        watchSessionReadiness(
            isSupported: link.isSupported,
            activationState: link.activationState,
            activationFailed: link.activationFailed
        ) {
            watchActivatedReadiness(
                isPaired: link.isPaired,
                isWatchAppInstalled: link.isWatchAppInstalled,
                facts: facts.snapshot
            )
        }
    }

    private static func status(seq: Int) -> WatchStatusContext {
        WatchStatusContext(
            phase: .observing,
            sessionID: "session-\(seq)",
            startedAt: Date(timeIntervalSince1970: 1_000),
            asOf: Date(timeIntervalSince1970: 1_015),
            seq: seq,
            queuedCount: 0,
            transferringCount: 0
        )
    }

    private static func pipelineInput(
        phoneSessionHistory: DiagnosticAvailability<WatchPhoneSessionHistoryInput> = .unavailable(reason: "not provided")
    ) -> WatchPipelineInput {
        WatchPipelineInput(
            now: Date(timeIntervalSince1970: 1_020),
            watchStatus: nil,
            lifetimeReceived: 0,
            lifetimeHanded: 0,
            nonTerminalCount: 0,
            lastHandedAt: nil,
            oldestNonTerminalReceivedAt: nil,
            lastLedgerError: nil,
            pendingCount: 0,
            failedCount: 0,
            inFlightCount: 0,
            lastUploadAt: nil,
            lastUploadError: nil,
            lastReceivedAt: nil,
            lastStagingError: nil,
            isPaired: true,
            isWatchAppInstalled: true,
            activationState: .activated,
            isReachable: true,
            isJournalReachable: true,
            phoneSessionHistory: phoneSessionHistory
        )
    }

    private static func historyEntry(now: Date) -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(
            sessionID: "history-session",
            startedAt: now.addingTimeInterval(-120),
            terminalAt: now,
            terminalReason: .audioClockStalled,
            terminalDisposition: .detectedStoppedItself,
            startRefusalReason: nil,
            settingsRoute: nil,
            noticeOwed: false,
            noticeDecision: "schedule",
            noticeDelivered: true,
            notificationAuthorizationStatus: .authorized,
            notificationAlertSetting: .enabled,
            wristAlertAssurance: .willTap,
            audioArmed: true,
            audioSessionIsActive: true,
            locationArmed: false,
            segmentsProduced: 1,
            batteryLevelAtEnd: nil,
            batteryStateAtEnd: nil,
            lowPowerModeEnabledAtEnd: nil,
            thermalStateAtEnd: nil,
            lastVerifiedAudioAt: nil,
            lastAudioCurrentTime: nil,
            zeroAudioCurrentTimeObservationCount: nil,
            locationAdvisory: nil,
            persistenceAdvisory: nil
        )
    }

    private static func historyPayload(entries: [WatchCaptureSessionHistoryEntry]) -> WatchRelayDiagnosticsPayload {
        WatchRelayDiagnosticsPayload(
            watchAppMarketingVersion: .available("0.1"),
            watchAppBuild: .available("1"),
            watchOSVersion: .available("26"),
            activationState: "activated",
            isCompanionAppInstalled: .available(true),
            isReachable: true,
            iOSDeviceNeedsUnlockAfterRebootForReachability: .available(false),
            hasContentPending: false,
            watchBatteryLevel: .available(0.5),
            watchBatteryState: .available("unplugged"),
            watchLowPowerModeEnabled: .available(false),
            watchThermalState: .available("nominal"),
            manifestSummary: .unavailable(reason: "not provided"),
            appleQueue: .unavailable(reason: "not provided"),
            lastFacts: .unavailable(reason: "not provided"),
            observedFileTransfers: [],
            omittedObservationCount: 0,
            sessionHistoryWindow: .available(entries),
            lifetimeSessionsStarted: .available(entries.count),
            sessionHistoryCounterEpoch: .available("epoch"),
            sessionHistoryDepth: entries.count
        )
    }

    @MainActor
    private static func historyStore() -> WatchPhoneSessionHistoryStore {
        WatchPhoneSessionHistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(WatchPhoneSessionHistoryStore.historyFileName),
            clock: Date.init
        )
    }

    @MainActor
    private static func defaults() -> UserDefaults {
        let suite = "WatchLinkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private static func facts() -> WatchSourceFacts {
        WatchSourceFacts(defaults: Self.defaults())
    }
}
