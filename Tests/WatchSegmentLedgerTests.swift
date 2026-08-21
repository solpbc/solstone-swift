// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchSegmentLedgerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSegmentLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.tempDirectory.path)
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testAC1ReceivePersistenceSurvivesRelaunch() {
        let id = UUID()
        let fileURL = self.ledgerFileURL("ac1")

        var ledger = WatchSegmentLedger(fileURL: fileURL)
        ledger.recordReceived(id: id)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 1)

        ledger = WatchSegmentLedger(fileURL: fileURL)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 1)
        XCTAssertFalse(ledger.isTerminal(id: id))
    }

    func testRecordReceivedIsIdempotentUntilPruned() {
        let id = UUID()
        let ledger = WatchSegmentLedger(fileURL: self.ledgerFileURL("received-idempotent"))

        ledger.recordReceived(id: id)
        ledger.recordReceived(id: id)

        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 1)
    }

    func testOldestNonTerminalReceivedAtExcludesTerminalAndNilReceivedAt() throws {
        let fileURL = self.ledgerFileURL("oldest-non-terminal")
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let handedAt = Date(timeIntervalSince1970: 3_000)
        let nilReceivedID = UUID().uuidString
        let terminalID = UUID().uuidString
        let olderID = UUID().uuidString
        let newerID = UUID().uuidString
        let store = WatchSegmentLedgerStore(
            entries: [
                nilReceivedID: WatchSegmentLedgerStore.Entry(),
                terminalID: WatchSegmentLedgerStore.Entry(receivedAt: Date(timeIntervalSince1970: 500), handedAt: handedAt),
                olderID: WatchSegmentLedgerStore.Entry(receivedAt: older),
                newerID: WatchSegmentLedgerStore.Entry(receivedAt: newer),
            ],
            lifetimeReceived: 4,
            lifetimeHanded: 1
        )
        try self.writeStore(store, to: fileURL)

        let ledger = WatchSegmentLedger(fileURL: fileURL)

        XCTAssertEqual(ledger.oldestNonTerminalReceivedAt, older)

        let emptyFileURL = self.ledgerFileURL("oldest-non-terminal-empty")
        let emptyStore = WatchSegmentLedgerStore(
            entries: [
                nilReceivedID: WatchSegmentLedgerStore.Entry(),
                terminalID: WatchSegmentLedgerStore.Entry(receivedAt: older, handedAt: handedAt),
            ],
            lifetimeReceived: 2,
            lifetimeHanded: 1
        )
        try self.writeStore(emptyStore, to: emptyFileURL)

        let emptyLedger = WatchSegmentLedger(fileURL: emptyFileURL)

        XCTAssertNil(emptyLedger.oldestNonTerminalReceivedAt)
    }

    func testCommittedOrTerminalSegmentIDsIncludesReceivedAndTerminalEntries() throws {
        let fileURL = self.ledgerFileURL("committed-or-terminal")
        let receivedID = UUID()
        let handedID = UUID()
        let droppedID = UUID()
        let ignoredID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let store = WatchSegmentLedgerStore(
            entries: [
                receivedID.uuidString: WatchSegmentLedgerStore.Entry(receivedAt: now),
                handedID.uuidString: WatchSegmentLedgerStore.Entry(receivedAt: now, handedAt: now),
                droppedID.uuidString: WatchSegmentLedgerStore.Entry(droppedAt: now),
                ignoredID.uuidString: WatchSegmentLedgerStore.Entry(),
                "not-a-uuid": WatchSegmentLedgerStore.Entry(receivedAt: now),
            ],
            lifetimeReceived: 4,
            lifetimeHanded: 1
        )
        try self.writeStore(store, to: fileURL)

        let ledger = WatchSegmentLedger(fileURL: fileURL)

        XCTAssertEqual(
            ledger.committedOrTerminalSegmentIDs.map(\.uuidString),
            [receivedID.uuidString, handedID.uuidString, droppedID.uuidString].sorted()
        )
    }

    func testAC6aUnknownIDBackfillsHandAndDropCounters() throws {
        let handedID = UUID()
        let droppedID = UUID()
        var now = Date(timeIntervalSince1970: 1_000)
        let fileURL = self.ledgerFileURL("ac6a")
        let ledger = WatchSegmentLedger(fileURL: fileURL, clock: { now })

        ledger.recordHanded(id: handedID)
        now = Date(timeIntervalSince1970: 2_000)
        ledger.recordDropped(id: droppedID)

        XCTAssertEqual(ledger.lifetimeReceived, 2)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 0)
        XCTAssertTrue(ledger.isTerminal(id: handedID))
        XCTAssertTrue(ledger.isTerminal(id: droppedID))

        let store = try self.loadStore(fileURL)
        let handed = try XCTUnwrap(store.entries[handedID.uuidString])
        XCTAssertEqual(handed.receivedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(handed.handedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(handed.droppedAt)

        let dropped = try XCTUnwrap(store.entries[droppedID.uuidString])
        XCTAssertNil(dropped.receivedAt)
        XCTAssertNil(dropped.handedAt)
        XCTAssertEqual(dropped.droppedAt, Date(timeIntervalSince1970: 2_000))

        let summary = WatchPipelineReducer.reduce(self.pipelineInput(
            lifetimeReceived: ledger.lifetimeReceived,
            nonTerminalCount: ledger.nonTerminalCount,
            lifetimeHanded: ledger.lifetimeHanded,
            lastHandedAt: ledger.lastHandedAt
        )).syncSummary
        XCTAssertLessThanOrEqual(summary.handedToJournal, summary.received)
    }

    func testTerminalConflictsKeepFirstTerminalState() throws {
        let dropThenHandID = UUID()
        let handThenDropID = UUID()
        let fileURL = self.ledgerFileURL("terminal-conflicts")
        let ledger = WatchSegmentLedger(fileURL: fileURL)

        ledger.recordDropped(id: dropThenHandID)
        ledger.recordHanded(id: dropThenHandID)
        ledger.recordHanded(id: handThenDropID)
        ledger.recordDropped(id: handThenDropID)

        XCTAssertEqual(ledger.lifetimeReceived, 2)
        XCTAssertEqual(ledger.lifetimeHanded, 1)

        let store = try self.loadStore(fileURL)
        let dropThenHand = try XCTUnwrap(store.entries[dropThenHandID.uuidString])
        XCTAssertNotNil(dropThenHand.droppedAt)
        XCTAssertNil(dropThenHand.handedAt)

        let handThenDrop = try XCTUnwrap(store.entries[handThenDropID.uuidString])
        XCTAssertNotNil(handThenDrop.handedAt)
        XCTAssertNil(handThenDrop.droppedAt)
    }

    func testAC7PrunesOldTerminalEntriesOnlyAndKeepsLifetimeCounters() {
        var now = Date(timeIntervalSince1970: 10_000)
        let ledger = WatchSegmentLedger(fileURL: self.ledgerFileURL("ac7"), clock: { now })
        let terminalID = UUID()
        let nonTerminalID = UUID()
        let triggerID = UUID()

        ledger.recordReceived(id: terminalID)
        ledger.recordHanded(id: terminalID)
        ledger.recordReceived(id: nonTerminalID)

        now = now.addingTimeInterval((8 * 24 * 60 * 60) + 1)
        ledger.recordReceived(id: triggerID)

        XCTAssertFalse(ledger.isTerminal(id: terminalID))
        XCTAssertEqual(ledger.lifetimeReceived, 3)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 2)

        ledger.recordReceived(id: terminalID)

        XCTAssertEqual(ledger.lifetimeReceived, 4)
        XCTAssertEqual(ledger.nonTerminalCount, 3)
    }

    func testAC8CorruptFileLoadsEmptyWithError() throws {
        let fileURL = self.ledgerFileURL("corrupt")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let ledger = WatchSegmentLedger(fileURL: fileURL)

        XCTAssertEqual(ledger.lifetimeReceived, 0)
        XCTAssertEqual(ledger.lifetimeHanded, 0)
        XCTAssertNotNil(ledger.lastLedgerError)

        ledger.recordReceived(id: UUID())
        XCTAssertNil(ledger.lastLedgerError)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testAC8PermanentWriteFailureNeverGatesInMemoryMutation() throws {
        let blocker = self.tempDirectory.appendingPathComponent("blocker", isDirectory: false)
        try Data("blocker".utf8).write(to: blocker)
        let ledger = WatchSegmentLedger(fileURL: blocker.appendingPathComponent("ledger.json", isDirectory: false))
        let receivedID = UUID()
        let handedID = UUID()
        let droppedID = UUID()

        ledger.recordReceived(id: receivedID)
        ledger.recordHanded(id: handedID)
        ledger.recordDropped(id: droppedID)

        XCTAssertEqual(ledger.lifetimeReceived, 3)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 1)
        XCTAssertTrue(ledger.isTerminal(id: handedID))
        XCTAssertTrue(ledger.isTerminal(id: droppedID))
        XCTAssertNotNil(ledger.lastLedgerError)
    }

    func testDeliveredHookPathRecordsHandedOnlyForSuccessfulWatchDelivery() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }

        let now = Date(timeIntervalSince1970: 12_000)
        let ledgerURL = self.ledgerFileURL("delivered-hook")
        let resolver = TransferEndpointResolverStub(.available(Self.endpoint()))
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("delivered-hook-transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: resolver
        )
        let pipeline = makeWatchPhonePipeline(
            transferEngine: harness.engine,
            transferStatusMirror: harness.mirror,
            transferEnqueuer: harness.enqueuer,
            watchConnectivitySession: MockWatchConnectivitySession(),
            watchSourceFacts: Self.watchSourceFacts(),
            ledgerFileURL: ledgerURL,
            ledgerClock: { now },
            drainStagingRootURL: self.tempDirectory.appendingPathComponent("delivered-hook-drain", isDirectory: true),
            receiverStagingRootURL: self.tempDirectory.appendingPathComponent("delivered-hook-receiver", isDirectory: true)
        )
        try await Task.sleep(for: .milliseconds(50))
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        try await harness.engine.start()

        let deliveredID = UUID()
        _ = try await harness.enqueuer.enqueueWatchSegment(
            manifest: Self.watchManifest(id: deliveredID, index: 1, now: now),
            audioData: Data("delivered".utf8),
            locationData: nil
        )
        try await self.waitFor("watch delivered hook ledger handoff") {
            pipeline.watchSegmentLedger.readSnapshot(asOf: now).value?.entriesByID[deliveredID]?.state == .handed
        }

        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 500), Data())
        }
        let failedID = UUID()
        _ = try await harness.enqueuer.enqueueWatchSegment(
            manifest: Self.watchManifest(id: failedID, index: 2, now: now),
            audioData: Data("failed".utf8),
            locationData: nil
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(
            pipeline.watchSegmentLedger.readSnapshot(asOf: now).value?.entriesByID[failedID]?.state,
            .handed
        )

        resolver.setResolution(.unavailable("held"))
        let inFlightID = UUID()
        _ = try await harness.enqueuer.enqueueWatchSegment(
            manifest: Self.watchManifest(id: inFlightID, index: 3, now: now),
            audioData: Data("held".utf8),
            locationData: nil
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(
            pipeline.watchSegmentLedger.readSnapshot(asOf: now).value?.entriesByID[inFlightID]?.state,
            .handed
        )

        await harness.engine.pause()
    }

    func testReadSnapshotIsReadOnlyAndRetainsOldTerminalEntriesOnDisk() throws {
        let fileURL = self.ledgerFileURL("read-snapshot")
        let asOf = Date(timeIntervalSince1970: 10_000)
        let receivedID = UUID()
        let handedID = UUID()
        let droppedID = UUID()
        let handedAndDroppedID = UUID()
        let oldTerminalID = UUID()
        let store = WatchSegmentLedgerStore(
            entries: [
                receivedID.uuidString: WatchSegmentLedgerStore.Entry(receivedAt: asOf.addingTimeInterval(-10)),
                handedID.uuidString: WatchSegmentLedgerStore.Entry(receivedAt: asOf.addingTimeInterval(-30), handedAt: asOf.addingTimeInterval(-20)),
                droppedID.uuidString: WatchSegmentLedgerStore.Entry(droppedAt: asOf.addingTimeInterval(-40)),
                handedAndDroppedID.uuidString: WatchSegmentLedgerStore.Entry(
                    receivedAt: asOf.addingTimeInterval(-70),
                    handedAt: asOf.addingTimeInterval(-60),
                    droppedAt: asOf.addingTimeInterval(-50)
                ),
                oldTerminalID.uuidString: WatchSegmentLedgerStore.Entry(
                    receivedAt: asOf.addingTimeInterval(-(8 * 24 * 60 * 60)),
                    handedAt: asOf.addingTimeInterval(-(8 * 24 * 60 * 60))
                ),
            ],
            lifetimeReceived: 5,
            lifetimeHanded: 3
        )
        try self.writeStore(store, to: fileURL)
        let before = try Data(contentsOf: fileURL)
        let ledger = WatchSegmentLedger(fileURL: fileURL, clock: { asOf })

        let snapshot = try XCTUnwrap(ledger.readSnapshot(asOf: asOf).value)

        XCTAssertEqual(snapshot.asOf, asOf)
        XCTAssertEqual(snapshot.counts.retainedEntryCount, 5)
        XCTAssertEqual(snapshot.counts.receivedOnlyCount, 1)
        XCTAssertEqual(snapshot.counts.handedCount, 2)
        XCTAssertEqual(snapshot.counts.droppedCount, 1)
        XCTAssertEqual(snapshot.counts.handedAndDroppedCount, 1)
        XCTAssertEqual(snapshot.entriesByID[receivedID]?.state, .received)
        XCTAssertEqual(snapshot.entriesByID[receivedID]?.receivedAgeSeconds, 10)
        XCTAssertEqual(snapshot.entriesByID[handedID]?.state, .handed)
        XCTAssertEqual(snapshot.entriesByID[handedID]?.handedAgeSeconds, 20)
        XCTAssertEqual(snapshot.entriesByID[droppedID]?.state, .dropped)
        XCTAssertEqual(snapshot.entriesByID[droppedID]?.droppedAgeSeconds, 40)
        XCTAssertEqual(snapshot.entriesByID[handedAndDroppedID]?.state, .handedAndDropped)
        XCTAssertEqual(snapshot.entriesByID[oldTerminalID]?.state, .handed)
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertNotNil(try self.loadStore(fileURL).entries[oldTerminalID.uuidString])
    }

    func testReadSnapshotSurfacesLastLedgerErrorAsUnavailable() throws {
        let fileURL = self.ledgerFileURL("read-snapshot-error")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let ledger = WatchSegmentLedger(fileURL: fileURL)

        let snapshot = ledger.readSnapshot(asOf: Date(timeIntervalSince1970: 1_000))

        XCTAssertNil(snapshot.value)
        XCTAssertNotNil(snapshot.unavailableReason)
        XCTAssertNotEqual(snapshot.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.absent)
    }

    private static func watchSourceFacts() -> WatchSourceFacts {
        let suite = "WatchSegmentLedgerTests-WatchFacts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WatchSourceFacts(defaults: defaults)
    }

    func testAC6bTransientWriteFailureSetsAndClearsLedgerError() throws {
        let directory = self.tempDirectory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = WatchSegmentLedger(fileURL: directory.appendingPathComponent("ledger.json", isDirectory: false))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        ledger.recordReceived(id: UUID())
        XCTAssertNotNil(ledger.lastLedgerError)
        let snapshotWithError = ledger.readSnapshot(asOf: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(snapshotWithError.value)
        XCTAssertFalse(snapshotWithError.unavailableReason?.contains(directory.path) ?? false)
        let rowsWithError = WatchPipelineReducer.reduce(self.pipelineInput(
            now: Date(timeIntervalSince1970: 1_000),
            lastLedgerError: ledger.lastLedgerError
        )).diagnosticsRows
        XCTAssertTrue(rowsWithError.contains { $0.label == SourceVocabulary.watchLastLedgerDetailLabel })

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        ledger.recordReceived(id: UUID())
        XCTAssertNil(ledger.lastLedgerError)
        let rowsWithoutError = WatchPipelineReducer.reduce(self.pipelineInput(
            now: Date(timeIntervalSince1970: 1_000),
            lastLedgerError: ledger.lastLedgerError
        )).diagnosticsRows
        XCTAssertFalse(rowsWithoutError.contains { $0.label == SourceVocabulary.watchLastLedgerDetailLabel })
    }
}

private extension WatchSegmentLedgerTests {
    func ledgerFileURL(_ name: String) -> URL {
        self.tempDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("ledger.json", isDirectory: false)
    }

    func loadStore(_ fileURL: URL) throws -> WatchSegmentLedgerStore {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WatchSegmentLedgerStore.self, from: data)
    }

    func writeStore(_ store: WatchSegmentLedgerStore, to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try data.write(to: fileURL)
    }

    nonisolated static func endpoint() -> TransferResolvedEndpoint {
        TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)
    }

    nonisolated static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    nonisolated static func watchManifest(id: UUID, index: Int, now: Date) -> WatchSegmentManifest {
        WatchSegmentManifest(
            id: id,
            day: "20260715",
            segment: String(format: "120%03d_300", index),
            startedAt: now.addingTimeInterval(TimeInterval(index)),
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .queued
        )
    }

    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    func pipelineInput(
        now: Date = Date(timeIntervalSince1970: 2_000),
        lifetimeReceived: Int = 0,
        nonTerminalCount: Int = 0,
        lifetimeHanded: Int = 0,
        lastHandedAt: Date? = nil,
        lastLedgerError: String? = nil
    ) -> WatchPipelineInput {
        WatchPipelineInput(
            now: now,
            watchStatus: nil,
            lifetimeReceived: lifetimeReceived,
            lifetimeHanded: lifetimeHanded,
            nonTerminalCount: nonTerminalCount,
            lastHandedAt: lastHandedAt,
            oldestNonTerminalReceivedAt: nil,
            lastLedgerError: lastLedgerError,
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
            isReachable: false,
            isJournalReachable: true,
            phoneSessionHistory: .unavailable(reason: "not provided")
        )
    }
}
