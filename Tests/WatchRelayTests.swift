// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity
import XCTest

@MainActor
final class WatchRelayTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchRelayTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testNeverLoseWithheldACKKeepsSegmentAndRelaunchResends() throws {
        let storage = try self.makeStorage("never-lose")
        let id = UUID()
        let directory = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)

        watchSession.activate()
        sender.drain()

        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        XCTAssertTrue(storage.fileWriter.fileExists(at: directory))
        let firstManifest = try XCTUnwrap(try storage.scanManifests().first?.manifest)
        XCTAssertEqual(firstManifest.id, id)
        XCTAssertEqual(firstManifest.state, .transferring)

        let relaunchedSession = MockWatchConnectivitySession()
        let relaunchedSender = WatchRelaySender(storage: storage, session: relaunchedSession)
        relaunchedSession.activate()
        relaunchedSender.drain()

        XCTAssertEqual(relaunchedSession.transferredFiles.count, 1)
        XCTAssertEqual(relaunchedSession.transferredFiles.first?.1["id"] as? String, id.uuidString)
        XCTAssertTrue(storage.fileWriter.fileExists(at: directory))
        let relaunchedManifest = try XCTUnwrap(try storage.scanManifests().first?.manifest)
        XCTAssertEqual(relaunchedManifest.state, .transferring)
    }

    func testNeverDuplicateRestagesOnceAndReACKsDuplicate() throws {
        let storage = try self.makeStorage("never-duplicate-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("never-duplicate-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)

        watchSession.outstandingFileTransfers.first?.cancel()
        sender.drain()
        XCTAssertEqual(watchSession.transferredFiles.count, 2)
        try self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 2)

        watchSession.deliverUserInfo(try XCTUnwrap(phoneSession.transferredUserInfos.last))

        XCTAssertFalse(storage.fileWriter.fileExists(at: sourceDirectory))
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
    }

    func testReachableACKUsesFastMessageAndDurableUserInfo() throws {
        let storage = try self.makeStorage("reachable-ack-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("reachable-ack-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        phoneSession.emitReachability(true)
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.sentMessages.count, 1)
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.sentMessages[0], id: id)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)

        watchSession.deliverUserInfo(phoneSession.sentMessages[0])

        XCTAssertFalse(storage.fileWriter.fileExists(at: sourceDirectory))
        XCTAssertEqual(try storage.scanManifests().count, 0)
    }

    func testUnreachableACKUsesOnlyDurableUserInfo() throws {
        let storage = try self.makeStorage("unreachable-ack-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("unreachable-ack-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertTrue(phoneSession.sentMessages.isEmpty)
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)

        watchSession.deliverUserInfo(phoneSession.transferredUserInfos[0])

        XCTAssertFalse(storage.fileWriter.fileExists(at: sourceDirectory))
        XCTAssertEqual(try storage.scanManifests().count, 0)
    }

    func testRelayACKTransfersDurableBeforeFastWhenReachable() throws {
        let storage = try self.makeStorage("reachable-ack-order-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("reachable-ack-order-staging", isDirectory: true)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        phoneSession.emitReachability(true)
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.callLedger.count, 2)
        guard phoneSession.callLedger.count == 2 else { return }
        self.assertRecordedTransferUserInfo(phoneSession.callLedger[0], id: id)
        self.assertRecordedSendMessage(phoneSession.callLedger[1], id: id)
    }

    func testRelayACKUnreachableRecordsOnlyDurableTransfer() throws {
        let storage = try self.makeStorage("unreachable-ack-order-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("unreachable-ack-order-staging", isDirectory: true)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.callLedger.count, 1)
        guard phoneSession.callLedger.count == 1 else { return }
        self.assertRecordedTransferUserInfo(phoneSession.callLedger[0], id: id)
    }

    func testFastAndDurableACKDeliveryIsIdempotent() throws {
        let storage = try self.makeStorage("idempotent-ack-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("idempotent-ack-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        phoneSession.emitReachability(true)
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.sentMessages.count, 1)
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)

        watchSession.deliverUserInfo(phoneSession.sentMessages[0])
        watchSession.deliverUserInfo(phoneSession.transferredUserInfos[0])

        XCTAssertFalse(storage.fileWriter.fileExists(at: sourceDirectory))
        XCTAssertEqual(try storage.scanManifests().count, 0)
    }

    func testSegmentStagedCallbackFiresForFreshAndDuplicateReceive() throws {
        let storage = try self.makeStorage("staged-callback-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("staged-callback-staging", isDirectory: true)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(stagedIDs, [id])

        watchSession.outstandingFileTransfers.first?.cancel()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(stagedIDs, [id, id])
    }

    func testReceiverInstrumentationTracksSuccessfulReceive() throws {
        let storage = try self.makeStorage("instrumentation-success-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("instrumentation-success-staging", isDirectory: true)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let ledger = self.makeLedger("instrumentation-success-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        let invalidScratch = self.tempDirectory.appendingPathComponent("invalid-watchrelay")
        try Data("not a segment bundle".utf8).write(to: invalidScratch, options: .atomic)
        receiver.receiveFile(invalidScratch, metadata: ["id": UUID().uuidString])
        XCTAssertNotNil(receiver.lastStagingError)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertNotNil(receiver.lastReceivedAt)
        XCTAssertNil(receiver.lastStagingError)

        let waiting = WatchPipelineReducer.reduce(self.pipelineInput(
            lifetimeReceived: ledger.lifetimeReceived,
            nonTerminalCount: ledger.nonTerminalCount,
            lifetimeHanded: ledger.lifetimeHanded,
            lastHandedAt: ledger.lastHandedAt
        )).syncSummary
        XCTAssertEqual(waiting.received, 1)
        XCTAssertEqual(waiting.waiting, 1)
        XCTAssertEqual(waiting.handedToJournal, 0)

        ledger.recordHanded(id: id)
        let handed = WatchPipelineReducer.reduce(self.pipelineInput(
            lifetimeReceived: ledger.lifetimeReceived,
            nonTerminalCount: ledger.nonTerminalCount,
            lifetimeHanded: ledger.lifetimeHanded,
            lastHandedAt: ledger.lastHandedAt
        )).syncSummary
        XCTAssertEqual(handed.received, 1)
        XCTAssertEqual(handed.waiting, 0)
        XCTAssertEqual(handed.handedToJournal, 1)
    }

    func testReceiverInstrumentationRefreshesDuplicateWithoutIncrementing() throws {
        let storage = try self.makeStorage("instrumentation-duplicate-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("instrumentation-duplicate-staging", isDirectory: true)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let ledger = self.makeLedger("instrumentation-duplicate-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)
        let firstReceivedAt = try XCTUnwrap(receiver.lastReceivedAt)
        Thread.sleep(forTimeInterval: 0.01)

        watchSession.outstandingFileTransfers.first?.cancel()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(ledger.lifetimeReceived, 1)
        let duplicateReceivedAt = try XCTUnwrap(receiver.lastReceivedAt)
        XCTAssertGreaterThan(duplicateReceivedAt.timeIntervalSinceReferenceDate, firstReceivedAt.timeIntervalSinceReferenceDate)
    }

    func testReceiverInstrumentationTracksStagingFailure() throws {
        let stagingRoot = self.tempDirectory.appendingPathComponent("instrumentation-failure-staging", isDirectory: true)
        let phoneSession = MockWatchConnectivitySession()
        let ledger = self.makeLedger("instrumentation-failure-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        let scratchURL = self.tempDirectory.appendingPathComponent("invalid-watchrelay")
        try Data("not a segment bundle".utf8).write(to: scratchURL, options: .atomic)
        defer { withExtendedLifetime(receiver) {} }

        receiver.receiveFile(scratchURL, metadata: ["id": UUID().uuidString])

        XCTAssertEqual(ledger.lifetimeReceived, 0)
        XCTAssertNil(receiver.lastReceivedAt)
        XCTAssertNotNil(receiver.lastStagingError)
    }

    func testAC4TerminalDuplicateShortCircuitsHandedAndDroppedIDs() throws {
        for terminalKind in ["handed", "dropped"] {
            let storage = try self.makeStorage("ac4-\(terminalKind)")
            let stagingRoot = self.tempDirectory.appendingPathComponent("ac4-\(terminalKind)-staging", isDirectory: true)
            let id = UUID()
            _ = try self.writeSegment(storage: storage, id: id, index: 0)
            let watchSession = MockWatchConnectivitySession()
            let phoneSession = MockWatchConnectivitySession()
            let sender = WatchRelaySender(storage: storage, session: watchSession)
            let ledger = self.makeLedger("ac4-\(terminalKind)-ledger")
            ledger.recordReceived(id: id)
            if terminalKind == "handed" {
                ledger.recordHanded(id: id)
            } else {
                ledger.recordDropped(id: id)
            }
            let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
            var stagedIDs: [UUID] = []
            receiver.onSegmentStaged = { stagedIDs.append($0) }
            defer { withExtendedLifetime(receiver) {} }

            watchSession.activate()
            sender.drain()
            try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

            XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
            self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)
            XCTAssertTrue(try self.stagedEntryIDs(at: stagingRoot).isEmpty)
            XCTAssertTrue(stagedIDs.isEmpty)
            XCTAssertNotNil(receiver.lastReceivedAt)
            XCTAssertEqual(ledger.lifetimeReceived, 1)
        }
    }

    func testAC5NonTerminalDuplicateReACKsAndRekicks() throws {
        let storage = try self.makeStorage("ac5-nonterminal-duplicate")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac5-nonterminal-staging", isDirectory: true)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let ledger = self.makeLedger("ac5-nonterminal-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)
        XCTAssertEqual(stagedIDs, [id])
        XCTAssertEqual(ledger.lifetimeReceived, 1)

        watchSession.outstandingFileTransfers.first?.cancel()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(phoneSession.transferredUserInfos.count, 2)
        XCTAssertEqual(stagedIDs, [id, id])
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testAC5MissingNonTerminalStagingRestagesAndRekicks() throws {
        let storage = try self.makeStorage("ac5-missing-staging")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac5-missing-staging-root", isDirectory: true)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let ledger = self.makeLedger("ac5-missing-ledger")
        ledger.recordReceived(id: id)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(stagedIDs, [id])
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testReplayACKsForCommittedSegmentsIncludesReceivedAndTerminalIDsWithoutStaging() throws {
        let stagingRoot = self.tempDirectory.appendingPathComponent("replay-ack-staging", isDirectory: true)
        let phoneSession = MockWatchConnectivitySession()
        let ledger = self.makeLedger("replay-ack-ledger")
        let receivedID = UUID()
        let handedID = UUID()
        let droppedID = UUID()
        ledger.recordReceived(id: receivedID)
        ledger.recordHanded(id: handedID)
        ledger.recordDropped(id: droppedID)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        receiver.replayACKsForCommittedSegments()

        XCTAssertEqual(
            phoneSession.transferredUserInfos.compactMap { $0[WatchRelayACK.idKey] as? String }.sorted(),
            [receivedID.uuidString, handedID.uuidString, droppedID.uuidString].sorted()
        )
        XCTAssertTrue(stagedIDs.isEmpty)
        XCTAssertTrue(try self.stagedEntryIDs(at: stagingRoot).isEmpty)
    }

    func testAC8CorruptLedgerStillStagesAndACKs() throws {
        let storage = try self.makeStorage("ac8-corrupt-ledger")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac8-corrupt-staging", isDirectory: true)
        let ledgerURL = self.tempDirectory
            .appendingPathComponent("ac8-corrupt-ledger-file", isDirectory: true)
            .appendingPathComponent("ledger.json", isDirectory: false)
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: ledgerURL)
        let ledger = WatchSegmentLedger(fileURL: ledgerURL)
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertNil(ledger.lastLedgerError)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testAC8PermanentLedgerWriteFailureStillStagesAndACKs() throws {
        let storage = try self.makeStorage("ac8-write-failure-ledger")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac8-write-failure-staging", isDirectory: true)
        let blocker = self.tempDirectory.appendingPathComponent("ac8-blocker", isDirectory: false)
        try Data("blocker".utf8).write(to: blocker)
        let ledger = WatchSegmentLedger(fileURL: blocker.appendingPathComponent("ledger.json", isDirectory: false))
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertNotNil(ledger.lastLedgerError)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testAC1EnqueueOnceDoesNotDuplicateWhileOutstanding() throws {
        let storage = try self.makeStorage("ac1-enqueue-once")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)

        watchSession.activate()
        sender.drain()
        sender.drain()

        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        XCTAssertEqual(watchSession.transferredFiles.first?.1["id"] as? String, id.uuidString)
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .transferring)
    }

    func testAC2FullQueueHandoffDrainsAllQueuedAtOnce() throws {
        let storage = try self.makeStorage("backlog-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("backlog-staging", isDirectory: true)
        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            _ = try self.writeSegment(storage: storage, id: id, index: index)
        }
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        sender.drain()

        XCTAssertEqual(watchSession.transferredFiles.count, 3)
        XCTAssertEqual(Set(watchSession.transferredFiles.compactMap { $0.1["id"] as? String }), Set(ids.map(\.uuidString)))
        for id in ids {
            XCTAssertEqual(try self.manifestState(storage: storage, id: id), .transferring)
        }

        for index in watchSession.transferredFiles.indices {
            try self.deliverTransfer(from: watchSession, index: index, to: phoneSession)
        }
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 3)
        for ack in phoneSession.transferredUserInfos.reversed() {
            watchSession.deliverUserInfo(ack)
        }

        XCTAssertEqual(Set(try self.stagedEntryIDs(at: stagingRoot)), Set(ids.map(\.uuidString)))
        XCTAssertEqual(try storage.scanManifests().count, 0)
    }

    func testAC3DidFinishMatrixUpdatesOnlyExpectedStates() throws {
        let storage = try self.makeStorage("ac3-finish-matrix")
        let watchSession = MockWatchConnectivitySession()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sender = WatchRelaySender(storage: storage, session: watchSession, clock: { now })
        watchSession.activate()

        let successID = UUID()
        let successDirectory = try self.writeSegment(storage: storage, id: successID, index: 0)
        sender.drain()
        let successBundleURL = sender.bundleURL(for: successID)
        XCTAssertTrue(storage.fileWriter.fileExists(at: successBundleURL))

        var stateChanges = 0
        sender.onStateChanged = { stateChanges += 1 }
        watchSession.finishTransfer(id: successID, failure: nil)

        XCTAssertEqual(try self.manifestState(storage: storage, id: successID), .delivered)
        XCTAssertEqual(try self.manifest(storage: storage, id: successID)?.deliveredAt, now)
        XCTAssertTrue(storage.fileWriter.fileExists(at: successDirectory))
        XCTAssertTrue(storage.fileWriter.fileExists(at: successBundleURL))
        XCTAssertEqual(stateChanges, 1)

        let queuedSuccessID = UUID()
        _ = try self.writeSegment(storage: storage, id: queuedSuccessID, index: 1)
        watchSession.finishTransfer(id: queuedSuccessID, failure: nil)
        XCTAssertEqual(try self.manifestState(storage: storage, id: queuedSuccessID), .delivered)
        XCTAssertEqual(try self.manifest(storage: storage, id: queuedSuccessID)?.deliveredAt, now)
        XCTAssertEqual(stateChanges, 2)

        watchSession.finishTransfer(id: queuedSuccessID, failure: nil)
        XCTAssertEqual(try self.manifestState(storage: storage, id: queuedSuccessID), .delivered)
        XCTAssertEqual(stateChanges, 2)

        let failureID = UUID()
        _ = try self.writeSegment(storage: storage, id: failureID, index: 2)
        sender.drain()
        let transferCountBeforeFailure = watchSession.transferredFiles.count
        watchSession.finishTransfer(id: failureID, failure: Self.transferFailure("network unavailable"))

        XCTAssertEqual(try self.manifestState(storage: storage, id: failureID), .queued)
        XCTAssertEqual(watchSession.transferredFiles.count, transferCountBeforeFailure)

        watchSession.finishTransfer(id: successID, failure: Self.transferFailure("late failure"))
        XCTAssertEqual(try self.manifestState(storage: storage, id: successID), .delivered)

        watchSession.finishTransfer(id: UUID(), failure: nil)
        watchSession.finishTransfer(id: UUID(), failure: Self.transferFailure("missing"))
        XCTAssertEqual(watchSession.transferredFiles.count, transferCountBeforeFailure)
    }

    func testAC4DeliveredWithoutTimestampStampsAndDoesNotRetransfer() throws {
        let storage = try self.makeStorage("ac4-delivered-nil")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0, state: .delivered)
        let watchSession = MockWatchConnectivitySession()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sender = WatchRelaySender(storage: storage, session: watchSession, clock: { now })
        let bundleURL = sender.bundleURL(for: id)
        try FileManager.default.createDirectory(at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("existing bundle".utf8)
        try marker.write(to: bundleURL, options: .atomic)

        watchSession.activate()
        sender.drain()

        XCTAssertTrue(watchSession.transferredFiles.isEmpty)
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .delivered)
        XCTAssertEqual(try self.manifest(storage: storage, id: id)?.deliveredAt, now)
        XCTAssertEqual(try Data(contentsOf: bundleURL), marker)
    }

    func testAC4DeliveredWithinDeadlineDoesNotRetransfer() throws {
        let storage = try self.makeStorage("ac4-delivered-fresh")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deliveredAt = now.addingTimeInterval(-60)
        _ = try self.writeSegment(
            storage: storage,
            id: id,
            index: 0,
            state: .delivered,
            deliveredAt: deliveredAt
        )
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession, clock: { now })
        let bundleURL = sender.bundleURL(for: id)
        try FileManager.default.createDirectory(at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("existing bundle".utf8)
        try marker.write(to: bundleURL, options: .atomic)

        watchSession.activate()
        sender.drain()

        XCTAssertTrue(watchSession.transferredFiles.isEmpty)
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .delivered)
        XCTAssertEqual(try self.manifest(storage: storage, id: id)?.deliveredAt, deliveredAt)
        XCTAssertEqual(try Data(contentsOf: bundleURL), marker)
    }

    func testAC4DeliveredPastDeadlineRequeuesAndRetransfers() throws {
        let storage = try self.makeStorage("ac4-delivered-expired")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try self.writeSegment(
            storage: storage,
            id: id,
            index: 0,
            state: .delivered,
            deliveredAt: now.addingTimeInterval(-900)
        )
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession, clock: { now })

        watchSession.activate()
        sender.drain()

        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        XCTAssertEqual(watchSession.transferredFiles.first?.1["id"] as? String, id.uuidString)
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .transferring)
        XCTAssertNil(try self.manifest(storage: storage, id: id)?.deliveredAt)
    }

    func testAC5FailureRetryViaNaturalDrainRequeuesAndRetries() throws {
        let storage = try self.makeStorage("ac5-failure-retry")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)

        watchSession.activate()
        sender.drain()
        XCTAssertEqual(watchSession.transferredFiles.count, 1)

        watchSession.finishTransfer(id: id, failure: Self.transferFailure("first failure"))
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .queued)
        XCTAssertEqual(watchSession.transferredFiles.count, 1)

        sender.drain()
        XCTAssertEqual(watchSession.transferredFiles.count, 2)
        watchSession.finishTransfer(id: id, failure: Self.transferFailure("second failure"))

        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .queued)
    }

    func testAC6BidirectionalReconcileHandlesOutstandingSnapshots() throws {
        let storageA = try self.makeStorage("ac6-absent")
        let absentID = UUID()
        _ = try self.writeSegment(storage: storageA, id: absentID, index: 0, state: .transferring)
        let sessionA = MockWatchConnectivitySession()
        let senderA = WatchRelaySender(storage: storageA, session: sessionA)
        sessionA.activate()
        senderA.drain()
        senderA.drain()
        XCTAssertEqual(sessionA.transferredFiles.count, 1)
        XCTAssertEqual(try self.manifestState(storage: storageA, id: absentID), .transferring)

        let storageB = try self.makeStorage("ac6-present")
        let presentID = UUID()
        _ = try self.writeSegment(storage: storageB, id: presentID, index: 0, state: .transferring)
        let sessionB = MockWatchConnectivitySession()
        sessionB.seedOutstandingTransfer(id: presentID)
        let senderB = WatchRelaySender(storage: storageB, session: sessionB)
        sessionB.activate()
        senderB.drain()
        XCTAssertTrue(sessionB.transferredFiles.isEmpty)
        XCTAssertTrue(sessionB.cancelledSegmentIDs.isEmpty)
        XCTAssertEqual(try self.manifestState(storage: storageB, id: presentID), .transferring)

        let storageC = try self.makeStorage("ac6-adopt")
        let adoptID = UUID()
        _ = try self.writeSegment(storage: storageC, id: adoptID, index: 0)
        let sessionC = MockWatchConnectivitySession()
        sessionC.seedOutstandingTransfer(id: adoptID)
        let senderC = WatchRelaySender(storage: storageC, session: sessionC)
        sessionC.activate()
        senderC.drain()
        XCTAssertTrue(sessionC.transferredFiles.isEmpty)
        XCTAssertEqual(sessionC.cancelledSegmentIDs, [])
        XCTAssertEqual(try self.manifestState(storage: storageC, id: adoptID), .transferring)

        let storageD = try self.makeStorage("ac6-duplicates")
        let duplicateID = UUID()
        let duplicateDirectory = try self.writeSegment(storage: storageD, id: duplicateID, index: 0)
        let sessionD = MockWatchConnectivitySession()
        sessionD.seedOutstandingTransfer(id: duplicateID)
        sessionD.seedOutstandingTransfer(id: duplicateID)
        let senderD = WatchRelaySender(storage: storageD, session: sessionD)
        sessionD.activate()
        senderD.drain()
        XCTAssertEqual(sessionD.cancelledSegmentIDs, [duplicateID])
        XCTAssertEqual(sessionD.outstandingFileTransfers.map(\.snapshot.segmentID), [duplicateID])
        XCTAssertTrue(storageD.fileWriter.fileExists(at: duplicateDirectory))

        let storageE = try self.makeStorage("ac6-orphans")
        let deliveredID = UUID()
        let deliveredDirectory = try self.writeSegment(storage: storageE, id: deliveredID, index: 0, state: .delivered)
        let missingID = UUID()
        let sessionE = MockWatchConnectivitySession()
        sessionE.seedOutstandingTransfer(id: nil)
        sessionE.seedOutstandingTransfer(id: missingID)
        sessionE.seedOutstandingTransfer(id: deliveredID)
        let senderE = WatchRelaySender(storage: storageE, session: sessionE)
        sessionE.activate()
        senderE.drain()
        XCTAssertEqual(sessionE.cancelledSegmentIDs.count, 3)
        XCTAssertTrue(sessionE.cancelledSegmentIDs.contains { $0 == nil })
        XCTAssertTrue(sessionE.cancelledSegmentIDs.contains(missingID))
        XCTAssertTrue(sessionE.cancelledSegmentIDs.contains(deliveredID))
        XCTAssertTrue(storageE.fileWriter.fileExists(at: deliveredDirectory))
        XCTAssertTrue(sessionE.transferredFiles.isEmpty)
    }

    func testAC7ActivationGateAndExactlyOnce() throws {
        let storage = try self.makeStorage("ac7-activation")
        let queuedID = UUID()
        let transferringID = UUID()
        _ = try self.writeSegment(storage: storage, id: queuedID, index: 0)
        _ = try self.writeSegment(storage: storage, id: transferringID, index: 1, state: .transferring)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)

        sender.drain()

        XCTAssertTrue(watchSession.transferredFiles.isEmpty)
        XCTAssertTrue(watchSession.cancelledSegmentIDs.isEmpty)
        XCTAssertEqual(try self.manifestState(storage: storage, id: queuedID), .queued)
        XCTAssertEqual(try self.manifestState(storage: storage, id: transferringID), .transferring)

        watchSession.activate()
        sender.drain()
        sender.drain()

        XCTAssertEqual(watchSession.transferredFiles.count, 2)
        XCTAssertEqual(Set(watchSession.transferredFiles.compactMap { $0.1["id"] as? String }), Set([queuedID.uuidString, transferringID.uuidString]))
        XCTAssertEqual(try self.manifestState(storage: storage, id: queuedID), .transferring)
        XCTAssertEqual(try self.manifestState(storage: storage, id: transferringID), .transferring)
    }

    func testAC8ACKOnDeliveredDeletesAndLateFinishNoops() throws {
        let storage = try self.makeStorage("ac8-ack-delivered")
        let id = UUID()
        let directory = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        watchSession.activate()
        sender.drain()
        let bundleURL = sender.bundleURL(for: id)
        XCTAssertTrue(storage.fileWriter.fileExists(at: bundleURL))

        watchSession.finishTransfer(id: id, failure: nil)
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .delivered)

        watchSession.deliverUserInfo(WatchRelayACK.userInfo(id: id))
        XCTAssertFalse(storage.fileWriter.fileExists(at: directory))
        XCTAssertFalse(storage.fileWriter.fileExists(at: bundleURL))
        XCTAssertEqual(try storage.scanManifests().count, 0)

        let transferCount = watchSession.transferredFiles.count
        watchSession.finishTransfer(id: id, failure: nil)
        watchSession.finishTransfer(id: id, failure: Self.transferFailure("late failure"))
        XCTAssertEqual(watchSession.transferredFiles.count, transferCount)
    }

    func testDrainUsesOneAdversarialOutstandingCaptureAndKeepsFirstDuplicate() throws {
        let storage = try self.makeStorage("single-capture")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let session = AdversarialOutstandingSession(segmentID: id)
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let sender = WatchRelaySender(storage: storage, session: session, diagnosticsStore: store)

        sender.drain()

        XCTAssertEqual(session.outstandingReadCount, 1)
        XCTAssertEqual(session.cancelledRuntimeTokens, [1])
        let reconciliation = try XCTUnwrap(store.readSummary().value?.lastQueueReconciliationObservation)
        XCTAssertEqual(reconciliation.observedFileTransferCount, 2)
        XCTAssertEqual(reconciliation.counts.duplicate, 1)
        XCTAssertEqual(reconciliation.counts.orphaned, 0)
    }

    func testTransfersUseDistinctAttemptIDsWithFrozenClock() throws {
        let storage = try self.makeStorage("distinct-attempts")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0)
        let session = MockWatchConnectivitySession()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sender = WatchRelaySender(storage: storage, session: session, clock: { now })
        session.activate()

        sender.drain()
        session.outstandingFileTransfers.first?.cancel()
        sender.drain()

        XCTAssertEqual(session.transferredFiles.count, 2)
        let first = session.transferredFiles[0].1
        let second = session.transferredFiles[1].1
        XCTAssertEqual(first["generation"] as? Int, 0)
        XCTAssertEqual(second["generation"] as? Int, 0)
        XCTAssertEqual(first["attempt_started_at"] as? String, second["attempt_started_at"] as? String)
        XCTAssertNotEqual(first["attempt_id"] as? String, second["attempt_id"] as? String)
    }

    func testReversedTaggedCompletionsRemainSegmentLevelOnly() throws {
        let storage = try self.makeStorage("reversed-completions")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0, state: .transferring)
        let firstAttempt = UUID()
        let secondAttempt = UUID()
        let session = MockWatchConnectivitySession()
        session.seedOutstandingTransfer(id: id, generation: 0, attemptID: firstAttempt)
        session.seedOutstandingTransfer(id: id, generation: 0, attemptID: secondAttempt)
        let sender = WatchRelaySender(storage: storage, session: session)

        session.finishTransfer(attemptID: secondAttempt, failure: nil)
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .delivered)

        session.finishTransfer(attemptID: firstAttempt, failure: Self.transferFailure("late failure"))
        XCTAssertEqual(try self.manifestState(storage: storage, id: id), .delivered)
    }

    func testAttemptRecordWriteFailureFallsBackToLegacyTransferAndContinuesDrain() throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("attempt-write-failure", fileWriter: writer)
        let firstID = UUID()
        let secondID = UUID()
        let firstDirectory = try self.writeSegment(storage: storage, id: firstID, index: 0)
        _ = try self.writeSegment(storage: storage, id: secondID, index: 1)
        let session = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: session)
        writer.failNextWriteData(at: firstDirectory.appendingPathComponent(WatchRelayAttemptRecord.filename))
        session.activate()

        sender.drain()

        XCTAssertEqual(session.transferredFiles.count, 2)
        XCTAssertNil(session.transferredFiles[0].1["generation"])
        XCTAssertNil(session.transferredFiles[0].1["attempt_id"])
        XCTAssertNil(session.transferredFiles[0].1["attempt_started_at"])
        XCTAssertFalse(writer.fileExists(at: firstDirectory.appendingPathComponent(WatchRelayAttemptRecord.filename)))
        XCTAssertEqual(session.transferredFiles[1].1["generation"] as? Int, 0)
    }

    func testRouteEvidenceCountsSuccessAndOnlyFirstDurableACK() throws {
        let storage = try self.makeStorage("route-evidence-events")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0, state: .transferring)
        let session = MockWatchConnectivitySession()
        let routeStore = WatchRelayRecoveryRouteStore(storage: storage)
        let sender = WatchRelaySender(storage: storage, session: session, recoveryRouteStore: routeStore)

        session.finishTransfer(id: id, failure: nil)
        var record = try XCTUnwrap(routeStore.establishRecord())
        XCTAssertEqual(record.successfulTransferGeneration, 1)
        XCTAssertEqual(record.durableACKGeneration, 0)

        let ack = WatchRelayACK.userInfo(id: id)
        session.deliverUserInfo(ack)
        record = try XCTUnwrap(routeStore.establishRecord())
        XCTAssertEqual(record.successfulTransferGeneration, 1)
        XCTAssertEqual(record.durableACKGeneration, 1)

        session.deliverUserInfo(ack)
        record = try XCTUnwrap(routeStore.establishRecord())
        XCTAssertEqual(record.successfulTransferGeneration, 1)
        XCTAssertEqual(record.durableACKGeneration, 1)
    }

    func testTransferFailureDoesNotAdvanceRouteSuccessGeneration() throws {
        let storage = try self.makeStorage("route-evidence-failure")
        let id = UUID()
        _ = try self.writeSegment(storage: storage, id: id, index: 0, state: .transferring)
        let session = MockWatchConnectivitySession()
        let routeStore = WatchRelayRecoveryRouteStore(storage: storage)
        let sender = WatchRelaySender(storage: storage, session: session, recoveryRouteStore: routeStore)

        session.finishTransfer(id: id, failure: Self.transferFailure("offline"))
        withExtendedLifetime(sender) {}

        let record = try XCTUnwrap(routeStore.establishRecord())
        XCTAssertEqual(record.successfulTransferGeneration, 0)
        XCTAssertEqual(record.durableACKGeneration, 0)
    }

    func testOwnerPresentationRelayStrings() {
        let queued = WatchCaptureOwnerPresentation(status: .off, queuedCount: 1)
        XCTAssertEqual(queued.headline, "saved on your watch")
        XCTAssertEqual(queued.countsLine, "1 saved on your watch")
        XCTAssertNil(queued.attentionLine)

        let transferring = WatchCaptureOwnerPresentation(status: .off, queuedCount: 1, transferringCount: 1)
        XCTAssertEqual(transferring.headline, "sending")
        XCTAssertEqual(transferring.countsLine, "1 sending · 1 saved on your watch")
        XCTAssertNil(transferring.attentionLine)

        let confirming = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, confirmingCount: 1)
        XCTAssertEqual(confirming.headline, "confirming with your iphone")
        XCTAssertEqual(confirming.countsLine, "1 confirming with your iphone")
        XCTAssertNil(confirming.attentionLine)

        let handedOff = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, handedOffCount: 1)
        XCTAssertEqual(handedOff.headline, "handed to your iphone")
        XCTAssertEqual(handedOff.countsLine, "1 handed to your iphone")
        XCTAssertNil(handedOff.attentionLine)

        let attention = WatchCaptureOwnerPresentation(
            status: .needsAttention(.diskFull),
            queuedCount: 1,
            transferringCount: 1,
            confirmingCount: 1,
            handedOffCount: 1
        )
        XCTAssertEqual(attention.headline, "storage is full")
        XCTAssertEqual(attention.countsLine, "1 sending · 1 saved on your watch · 1 confirming with your iphone · 1 handed to your iphone")
        XCTAssertEqual(attention.attentionLine, "storage is full")
    }
}

@MainActor
private extension WatchRelayTests {
    func makeLedger(_ name: String) -> WatchSegmentLedger {
        WatchSegmentLedger(
            fileURL: self.tempDirectory
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("ledger.json", isDirectory: false)
        )
    }

    func makeReceiver(
        session: MockWatchConnectivitySession,
        stagingRoot: URL,
        ledger: WatchSegmentLedger? = nil
    ) throws -> WatchRelayReceiver {
        try WatchRelayReceiver(
            session: session,
            ledger: ledger ?? self.makeLedger("receiver-ledger-\(UUID().uuidString)"),
            stagingRootURL: stagingRoot,
            facts: self.watchSourceFacts()
        )
    }

    func watchSourceFacts() -> WatchSourceFacts {
        let suite = "WatchRelayTests-WatchFacts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WatchSourceFacts(defaults: defaults)
    }

    func pipelineInput(
        now: Date = Date(timeIntervalSince1970: 2_000),
        lifetimeReceived: Int = 0,
        nonTerminalCount: Int = 0,
        lifetimeHanded: Int = 0,
        lastHandedAt: Date? = nil
    ) -> WatchPipelineInput {
        WatchPipelineInput(
            now: now,
            watchStatus: nil,
            lifetimeReceived: lifetimeReceived,
            lifetimeHanded: lifetimeHanded,
            nonTerminalCount: nonTerminalCount,
            lastHandedAt: lastHandedAt,
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
            isReachable: false,
            isJournalReachable: true,
            phoneSessionHistory: .unavailable(reason: "not provided")
        )
    }

    func makeStorage(_ name: String) throws -> WatchCaptureStorage {
        try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true))
    }

    func makeStorage(_ name: String, fileWriter: any WatchFileWriting) throws -> WatchCaptureStorage {
        try WatchCaptureStorage(
            rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true),
            fileWriter: fileWriter
        )
    }

    func writeSegment(
        storage: WatchCaptureStorage,
        id: UUID,
        index: Int,
        state: WatchSegmentState = .queued,
        deliveredAt: Date? = nil
    ) throws -> URL {
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000 + Double(index * 60))
        let day = storage.dayString(for: startedAt)
        let segment = storage.segmentString(for: startedAt, durationSeconds: 60)
        let directory = try storage.ensureSegmentDirectory(day: day, segment: segment)
        let manifest = WatchSegmentManifest(
            id: id,
            day: day,
            segment: segment,
            startedAt: startedAt,
            duration: 60,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: state,
            failureReason: nil,
            deliveredAt: deliveredAt
        )
        try Data("audio-\(index)".utf8).write(to: storage.audioURL(directory: directory), options: .atomic)
        try storage.writeManifest(manifest, in: directory)
        return directory
    }

    func deliverTransfer(
        from watchSession: MockWatchConnectivitySession,
        index: Int,
        to phoneSession: MockWatchConnectivitySession
    ) throws {
        let transfer = watchSession.transferredFiles[index]
        let scratchDirectory = self.tempDirectory.appendingPathComponent("delivered-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let scratchURL = scratchDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("watchrelay")
        try FileManager.default.copyItem(at: transfer.0, to: scratchURL)
        phoneSession.deliverFile(scratchURL, metadata: transfer.1)
    }

    func stagedEntryIDs(at stagingRoot: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: stagingRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map(\.lastPathComponent)
        .filter { $0 != WatchRelayReceiver.incomingDirectoryName }
        .sorted()
    }

    func manifest(storage: WatchCaptureStorage, id: UUID) throws -> WatchSegmentManifest? {
        try storage.scanManifests().first { $0.manifest.id == id }?.manifest
    }

    func manifestState(storage: WatchCaptureStorage, id: UUID) throws -> WatchSegmentState {
        try XCTUnwrap(try self.manifest(storage: storage, id: id)).state
    }

    func assertRelayACK(
        _ userInfo: [String: Any],
        id: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(userInfo[WatchRelayACK.typeKey] as? String, WatchRelayACK.type, file: file, line: line)
        XCTAssertEqual(userInfo[WatchRelayACK.idKey] as? String, id.uuidString, file: file, line: line)
    }

    func assertRecordedTransferUserInfo(
        _ call: MockWatchConnectivitySession.RecordedCall,
        id: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch call {
        case let .transferUserInfo(userInfo):
            self.assertRelayACK(userInfo, id: id, file: file, line: line)
        default:
            XCTFail("expected transferUserInfo call", file: file, line: line)
        }
    }

    func assertRecordedSendMessage(
        _ call: MockWatchConnectivitySession.RecordedCall,
        id: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch call {
        case let .sendMessage(message):
            self.assertRelayACK(message, id: id, file: file, line: line)
        default:
            XCTFail("expected sendMessage call", file: file, line: line)
        }
    }

    static func transferFailure(_ description: String) -> WatchConnectivityTransferFailureSnapshot {
        WatchConnectivityTransferFailureSnapshot(
            domain: "MockWatchConnectivity",
            code: 1,
            boundedRedactedDescription: description
        )
    }
}

@MainActor
private final class AdversarialOutstandingSession: WatchConnectivitySession {
    let isSupported = true
    let isReachable = false
    let isPaired = false
    let isWatchAppInstalled = false
    let activationState: WCSessionActivationState = .activated
    let hasContentPending = false
    let receivedApplicationContext: [String: Any] = [:]
    var outstandingUserInfoTransferSnapshots: [WatchConnectivityUserInfoTransferSnapshot] = []
    var isCompanionAppInstalledForDiagnostics: DiagnosticAvailability<Bool> = .unavailable(reason: "not configured")
    var iOSDeviceNeedsUnlockAfterRebootForDiagnostics: DiagnosticAvailability<Bool> = .unavailable(reason: "not configured")
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onWatchStateChanged: (@Sendable () -> Void)?
    var onReceiveFile: ((URL, [String: Any]) -> Void)?
    var onReceiveUserInfo: (([String: Any]) -> Void)?
    var onReceiveApplicationContext: (([String: Any]) -> Void)?
    var onFileTransferFinished: ((WatchConnectivityFileTransferCompletion) -> Void)?
    var onSessionEvent: (() -> Void)?
    private(set) var outstandingReadCount = 0
    private let cancellationLedger: CancellationLedger
    var cancelledRuntimeTokens: [Int] { self.cancellationLedger.tokens }
    private let first: [WatchConnectivityFileTransferObservation]
    private let second: [WatchConnectivityFileTransferObservation]

    var outstandingFileTransfers: [WatchConnectivityFileTransferObservation] {
        self.outstandingReadCount += 1
        return self.outstandingReadCount == 1 ? self.first : self.second
    }

    init(segmentID: UUID) {
        let cancellationLedger = CancellationLedger()
        self.cancellationLedger = cancellationLedger
        let snapshot = WatchConnectivityFileTransferSnapshot(
            asOf: Date(timeIntervalSince1970: 0),
            segmentID: segmentID,
            idState: .parseable,
            isTransferring: true,
            progress: MockWatchConnectivitySession.defaultProgress()
        )
        var first: [WatchConnectivityFileTransferObservation] = []
        first = [0, 1].map { token in
            WatchConnectivityFileTransferObservation(
                runtimeToken: WatchConnectivityFileTransferRuntimeToken(value: token),
                snapshot: snapshot,
                generation: nil,
                generationState: .missing,
                attemptID: nil,
                attemptIDState: .missing,
                attemptStartedAt: nil,
                attemptStartedAtState: .missing
            ) {
                cancellationLedger.tokens.append(token)
            }
        }
        self.first = first
        let orphanSnapshot = WatchConnectivityFileTransferSnapshot(
            asOf: Date(timeIntervalSince1970: 1),
            segmentID: UUID(),
            idState: .parseable,
            isTransferring: true,
            progress: MockWatchConnectivitySession.defaultProgress()
        )
        self.second = [
            first[1],
            first[0],
            WatchConnectivityFileTransferObservation(
                runtimeToken: WatchConnectivityFileTransferRuntimeToken(value: 2),
                snapshot: orphanSnapshot,
                generation: nil,
                generationState: .missing,
                attemptID: nil,
                attemptIDState: .missing,
                attemptStartedAt: nil,
                attemptStartedAtState: .missing,
                cancel: {}
            ),
        ]
    }

    func activate() {}
    func transferFile(_ url: URL, metadata: [String: Any]) {}
    func transferUserInfo(_ userInfo: [String: Any]) {}
    func sendMessage(_ message: [String: Any]) {}
    func updateApplicationContext(_ applicationContext: [String: Any]) throws {}
}

@MainActor
private final class CancellationLedger {
    var tokens: [Int] = []
}
