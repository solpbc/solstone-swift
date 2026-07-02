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

    func testAC6bTransientWriteFailureSetsAndClearsLedgerError() throws {
        let directory = self.tempDirectory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = WatchSegmentLedger(fileURL: directory.appendingPathComponent("ledger.json", isDirectory: false))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        ledger.recordReceived(id: UUID())
        XCTAssertNotNil(ledger.lastLedgerError)
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
            isJournalReachable: true
        )
    }
}
