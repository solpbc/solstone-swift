// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity
import XCTest

@MainActor
final class WatchPhoneSessionHistoryStoreTests: XCTestCase {
    private var root: URL!
    private var now: Date!

    override func setUpWithError() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        self.now = Date(timeIntervalSince1970: 2_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root)
    }

    func testMergeUnionsWindowsAndRetainsSessionsMissingFromLaterWindow() throws {
        let store = self.store()
        XCTAssertTrue(store.merge(diagnostics: self.diagnostics([self.entry("one"), self.entry("two")]), status: nil))
        XCTAssertTrue(store.merge(diagnostics: self.diagnostics([self.entry("three")]), status: nil))

        let snapshot = try XCTUnwrap(store.readSnapshot(asOf: self.now).value)
        XCTAssertEqual(Set(snapshot.entries.map(\.sessionID)), Set(["one", "two", "three"]))
        XCTAssertEqual(snapshot.distinctMergedTotal, 3)
    }

    func testReapplyingIdenticalDiagnosticsReturnsFalseAndLeavesSnapshotEqual() throws {
        let store = self.store()
        let diagnostics = self.diagnostics([self.entry("one")])
        XCTAssertTrue(store.merge(diagnostics: diagnostics, status: nil))
        let first = try XCTUnwrap(store.readSnapshot(asOf: self.now).value)

        XCTAssertFalse(store.merge(diagnostics: diagnostics, status: nil))
        XCTAssertEqual(store.readSnapshot(asOf: self.now).value, first)
    }

    func testCompleteEntryWinsInBothArrivalOrders() throws {
        let live = self.entry("one", complete: false, reason: nil, noticeDelivered: nil)
        let complete = self.entry("one", terminal: self.now, reason: .audioClockStalled, noticeDelivered: true)

        let firstStore = self.store(name: "first")
        _ = firstStore.merge(diagnostics: self.diagnostics([live]), status: nil)
        _ = firstStore.merge(diagnostics: self.diagnostics([complete]), status: nil)

        let secondStore = self.store(name: "second")
        _ = secondStore.merge(diagnostics: self.diagnostics([complete]), status: nil)
        _ = secondStore.merge(diagnostics: self.diagnostics([live]), status: nil)

        let first = try XCTUnwrap(firstStore.readSnapshot(asOf: self.now).value?.entries.first)
        let second = try XCTUnwrap(secondStore.readSnapshot(asOf: self.now).value?.entries.first)
        XCTAssertEqual(first.terminalReason, .audioClockStalled)
        XCTAssertEqual(first.noticeDelivered, true)
        XCTAssertEqual(second.terminalReason, .audioClockStalled)
        XCTAssertEqual(second.noticeDelivered, true)
    }

    func testSparseLaterEntryDoesNotClearKnownOptionalFields() throws {
        let complete = self.entry("one", terminal: self.now, reason: .audioClockStalled, noticeDelivered: true)
        let sparse = self.entry("one", complete: false, reason: nil, noticeDelivered: nil)
        let store = self.store()

        _ = store.merge(diagnostics: self.diagnostics([complete]), status: nil)
        _ = store.merge(diagnostics: self.diagnostics([sparse]), status: nil)

        let entry = try XCTUnwrap(store.readSnapshot(asOf: self.now).value?.entries.first)
        XCTAssertEqual(entry.terminalReason, .audioClockStalled)
        XCTAssertEqual(entry.noticeDelivered, true)
    }

    func testRelaunchAndPureSnapshotAgeAccounting() throws {
        let fileURL = self.fileURL("relaunch")
        let old = self.entry(
            "old",
            startedAt: self.now.addingTimeInterval(-8 * 24 * 60 * 60),
            terminal: self.now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let fresh = self.entry("fresh")
        let store = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        _ = store.merge(diagnostics: self.diagnostics([old, fresh]), status: nil)

        let reloaded = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        let snapshot = try XCTUnwrap(reloaded.readSnapshot(asOf: self.now).value)
        XCTAssertEqual(snapshot.entries.map(\.sessionID), ["fresh"])
        XCTAssertEqual(snapshot.prunedForAgeTotal, 1)
        XCTAssertEqual(snapshot.retainedCount + snapshot.prunedForAgeTotal, snapshot.distinctMergedTotal)
    }

    func testFutureTimestampUsesFirstReceiptTimeAndIdenticalReapplyIsANoOp() throws {
        let fileURL = self.fileURL("future")
        let future = self.entry("future", terminal: self.now.addingTimeInterval(365 * 24 * 60 * 60), reason: .audioClockStalled, noticeDelivered: true)
        let diagnostics = self.diagnostics([future])
        let store = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        XCTAssertTrue(store.merge(diagnostics: diagnostics, status: nil))
        let retainedAtSixDays = try XCTUnwrap(store.readSnapshot(asOf: self.now.addingTimeInterval(6 * 24 * 60 * 60)).value)

        self.now = self.now.addingTimeInterval(24 * 60 * 60)
        XCTAssertFalse(store.merge(diagnostics: diagnostics, status: nil))
        XCTAssertEqual(store.readSnapshot(asOf: self.now.addingTimeInterval(5 * 24 * 60 * 60)).value, retainedAtSixDays)
        XCTAssertEqual(store.readSnapshot(asOf: self.now.addingTimeInterval(7 * 24 * 60 * 60)).value?.retainedCount, 0)
    }

    func testDamagedTailIsUnavailableButPreservesRecoverableRecordsAndMergesResume() throws {
        let fileURL = self.fileURL("damage")
        let store = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        _ = store.merge(diagnostics: self.diagnostics([self.entry("recoverable")]), status: nil)

        var data = try Data(contentsOf: fileURL)
        data.append(Data("bad tail\n".utf8))
        try data.write(to: fileURL, options: .atomic)
        let damaged = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        XCTAssertEqual(damaged.readSnapshot(asOf: self.now).unavailableReason, WatchRelayDiagnosticsEnvelopeReason.sessionHistoryUnreadable)
        XCTAssertTrue(try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8)).contains("recoverable"))
        XCTAssertTrue(damaged.merge(diagnostics: self.diagnostics([self.entry("later")]), status: nil))
        let persisted = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        XCTAssertTrue(persisted.contains("recoverable"))
        XCTAssertTrue(persisted.contains("later"))
    }

    func testDamagedMetadataPersistsNewSessionsAndRebasesWhenCountersReturn() throws {
        let fileURL = self.fileURL("damaged-metadata")
        let store = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        _ = store.merge(diagnostics: self.diagnostics([self.entry("recoverable")]), status: nil)

        let damagedMetadata = Data("damaged metadata".utf8)
        let originalData = try Data(contentsOf: fileURL)
        let originalLines: [Data] = originalData.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        try self.write(lines: [damagedMetadata] + Array(originalLines.dropFirst()), to: fileURL)

        let damaged = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: damaged.readSnapshot(asOf: self.now)).unavailableReason,
            WatchRelayDiagnosticsEnvelopeReason.sessionHistoryUnreadable
        )
        XCTAssertTrue(damaged.merge(diagnostics: self.diagnosticsWithUnavailableCounters([self.entry("later")]), status: nil))

        let afterUnavailableCounters = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        XCTAssertTrue(afterUnavailableCounters.contains("damaged metadata"))
        XCTAssertTrue(afterUnavailableCounters.contains("recoverable"))
        XCTAssertTrue(afterUnavailableCounters.contains("later"))

        let reloaded = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        XCTAssertTrue(reloaded.merge(
            diagnostics: self.diagnostics([self.entry("rebased")], lifetime: 100),
            status: nil
        ))
        let persisted = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        XCTAssertTrue(persisted.contains("later"))
        XCTAssertTrue(persisted.contains("rebased"))

        let persistedData = try Data(contentsOf: fileURL)
        let repairedLines: [Data] = persistedData
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
            .filter { $0 != damagedMetadata }
        try self.write(lines: repairedLines, to: fileURL)
        let recovered = WatchPhoneSessionHistoryStore(fileURL: fileURL, clock: { self.now })
        let snapshot = try XCTUnwrap(recovered.readSnapshot(asOf: self.now).value)
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(snapshot)).value?.sessionsNotReceived,
            .available(0)
        )
    }

    func testLiveUnmergedSessionIsExcludedFromAdjustedWatchStartedAndHonestyRow() throws {
        let store = self.store()
        let status = self.status(phase: .observing, sessionID: "live")
        XCTAssertTrue(store.merge(
            diagnostics: self.diagnostics([self.entry("stored")], lifetime: 51),
            status: status
        ))

        let snapshot = try XCTUnwrap(store.readSnapshot(asOf: self.now).value)
        XCTAssertEqual(snapshot.adjustedWatchStarted, .available(50))
        let input = try XCTUnwrap(WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(snapshot)).value)
        XCTAssertEqual(input.sessionsNotReceived, .available(0))
    }

    func testOnlyAnUnmergedNonIdleSessionIsExcludedFromAdjustedWatchStarted() throws {
        let cases: [(String, WatchStatusContext)] = [
            ("idle", self.status(phase: .idle, sessionID: "live")),
            ("missing-id", self.status(phase: .observing, sessionID: nil)),
            ("already-merged", self.status(phase: .observing, sessionID: "stored")),
        ]

        for (name, status) in cases {
            let store = self.store(name: name)
            XCTAssertTrue(store.merge(
                diagnostics: self.diagnostics([self.entry("stored")], lifetime: 51),
                status: status
            ))
            XCTAssertEqual(store.readSnapshot(asOf: self.now).value?.adjustedWatchStarted, .available(51))
        }
    }

    func testFirstMergeCapturesNewIphoneBaselineAndHonestyRowIsZero() throws {
        let store = self.store()
        XCTAssertTrue(store.merge(diagnostics: self.diagnostics([self.entry("first")], lifetime: 50), status: nil))

        let snapshot = try XCTUnwrap(store.readSnapshot(asOf: self.now).value)
        XCTAssertEqual(snapshot.baselineEpoch, "epoch")
        XCTAssertEqual(snapshot.baselineAdjustedWatchStarted, 50)
        XCTAssertEqual(snapshot.baselineDistinctMerged, 1)
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(snapshot)).value?.sessionsNotReceived,
            .available(0)
        )
    }

    func testNextMergeableWindowRebasesBaselineWhenCounterEpochChanges() throws {
        let store = self.store()
        _ = store.merge(diagnostics: self.diagnostics([self.entry("first")], lifetime: 50, epoch: "old"), status: nil)
        XCTAssertTrue(store.merge(
            diagnostics: self.diagnostics([self.entry("first"), self.entry("second")], lifetime: 51, epoch: "new"),
            status: nil
        ))

        let snapshot = try XCTUnwrap(store.readSnapshot(asOf: self.now).value)
        XCTAssertEqual(snapshot.baselineEpoch, "new")
        XCTAssertEqual(snapshot.baselineAdjustedWatchStarted, 51)
        XCTAssertEqual(snapshot.baselineDistinctMerged, 2)
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(snapshot)).value?.sessionsNotReceived,
            .available(0)
        )
    }

    func testOmittedWindowSessionStillRendersInDiagnosticsExport() throws {
        let store = self.store()
        let omitted = self.entry("omitted", reason: .audioClockStalled)
        let later = self.entry("later", reason: .audioRecorderStopped)
        _ = store.merge(diagnostics: self.diagnostics([omitted], lifetime: 1), status: nil)
        _ = store.merge(diagnostics: self.diagnostics([later], lifetime: 2), status: nil)

        let snapshot = try XCTUnwrap(store.readSnapshot(asOf: self.now).value)
        let history = WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(snapshot))
        XCTAssertTrue(self.diagnosticsExport(phoneSessionHistory: history).contains(
            "outcome: audio-clock-stalled / detected-stopped-itself"
        ))
    }

    private func store(name: String = "history") -> WatchPhoneSessionHistoryStore {
        WatchPhoneSessionHistoryStore(fileURL: self.fileURL(name), clock: { self.now })
    }

    private func fileURL(_ name: String) -> URL {
        self.root.appendingPathComponent("\(name).jsonl", isDirectory: false)
    }

    private func diagnostics(
        _ entries: [WatchCaptureSessionHistoryEntry],
        lifetime: Int? = nil,
        epoch: String = "epoch"
    ) -> WatchRelayDiagnosticsEnvelopeResult {
        .available(self.payload(entries, lifetime: lifetime ?? entries.count, epoch: epoch), rawEnvelopeByteCount: nil)
    }

    private func diagnosticsWithUnavailableCounters(
        _ entries: [WatchCaptureSessionHistoryEntry]
    ) -> WatchRelayDiagnosticsEnvelopeResult {
        .available(self.payload(
            entries,
            lifetime: entries.count,
            epoch: "epoch",
            lifetimeSessionsStarted: .unavailable(reason: SourceVocabulary.watchDiagnosticsNotProvided),
            sessionHistoryCounterEpoch: .unavailable(reason: SourceVocabulary.watchDiagnosticsNotProvided)
        ), rawEnvelopeByteCount: nil)
    }

    private func status(phase: WatchStatusContext.Phase, sessionID: String?) -> WatchStatusContext {
        WatchStatusContext(
            phase: phase,
            sessionID: sessionID,
            startedAt: phase == .idle ? nil : self.now.addingTimeInterval(-60),
            asOf: self.now,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0
        )
    }

    private func diagnosticsExport(
        phoneSessionHistory: DiagnosticAvailability<WatchPhoneSessionHistoryInput>
    ) -> String {
        WatchPipelineReducer.reduce(WatchPipelineInput(
            now: self.now,
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
        )).diagnosticsExportText
    }

    private func entry(
        _ id: String,
        startedAt: Date? = nil,
        terminal: Date? = nil,
        complete: Bool = true,
        reason: WatchCaptureTerminalReason? = .audioClockStalled,
        noticeDelivered: Bool? = true
    ) -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(
            sessionID: id,
            startedAt: startedAt ?? self.now.addingTimeInterval(-60),
            terminalAt: complete ? terminal ?? self.now : nil,
            terminalReason: reason,
            terminalDisposition: reason == nil ? nil : .detectedStoppedItself,
            startRefusalReason: nil,
            settingsRoute: nil,
            noticeOwed: false,
            noticeDecision: "schedule",
            noticeDelivered: noticeDelivered,
            notificationAuthorizationStatus: .authorized,
            notificationAlertSetting: .enabled,
            wristAlertAssurance: .willTap,
            audioArmed: true,
            audioSessionIsActive: true,
            locationArmed: false,
            segmentsProduced: 1,
            batteryLevelAtEnd: 0.5,
            batteryStateAtEnd: "unplugged",
            lowPowerModeEnabledAtEnd: false,
            thermalStateAtEnd: "nominal",
            lastVerifiedAudioAt: self.now,
            lastAudioCurrentTime: 1,
            zeroAudioCurrentTimeObservationCount: 0,
            locationAdvisory: nil,
            persistenceAdvisory: nil
        )
    }

    private func payload(
        _ entries: [WatchCaptureSessionHistoryEntry],
        lifetime: Int,
        epoch: String,
        lifetimeSessionsStarted: DiagnosticAvailability<Int>? = nil,
        sessionHistoryCounterEpoch: DiagnosticAvailability<String>? = nil
    ) -> WatchRelayDiagnosticsPayload {
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
            lifetimeSessionsStarted: lifetimeSessionsStarted ?? .available(lifetime),
            sessionHistoryCounterEpoch: sessionHistoryCounterEpoch ?? .available(epoch),
            sessionHistoryDepth: entries.count
        )
    }

    private func write(lines: [Data], to fileURL: URL) throws {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
    }
}
