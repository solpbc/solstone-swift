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

    private func catalogEntries(for storage: WatchCaptureTestStorage) async -> [WatchCaptureCatalogEntry] {
        await WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: storage.fileWriter
        ).scanCatalog(transactionClass: .maintenance).entries
    }

    private func storageActor(for storage: WatchCaptureTestStorage) -> WatchCaptureStorageActor {
        WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: storage.fileWriter
        )
    }

    func testNeverLoseWithheldACKKeepsSegmentAndRelaunchResends() async throws {
        let storage = try self.makeStorage("never-lose")
        let id = UUID()
        let directory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        let directoryExists = await storage.fileWriter.fileExists(at: directory)
        XCTAssertTrue(directoryExists)
        let firstEntries = await self.catalogEntries(for: storage)
        let firstManifest = try XCTUnwrap(firstEntries.first?.manifest)
        XCTAssertEqual(firstManifest.id, id)
        XCTAssertEqual(firstManifest.state, .transferring)

        let relaunchedSession = MockWatchConnectivitySession()
        let relaunchedSender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: relaunchedSession)
        relaunchedSession.activate()
        await relaunchedSender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(relaunchedSession.transferredFiles.count, 1)
        XCTAssertEqual(relaunchedSession.transferredFiles.first?.1["id"] as? String, id.uuidString)
        let directoryExistsAfterRelaunch = await storage.fileWriter.fileExists(at: directory)
        XCTAssertTrue(directoryExistsAfterRelaunch)
        let relaunchedEntries = await self.catalogEntries(for: storage)
        let relaunchedManifest = try XCTUnwrap(relaunchedEntries.first?.manifest)
        XCTAssertEqual(relaunchedManifest.state, .transferring)
    }

    func testWatchSegmentBuffersWithoutPhoneThenStagesAndDrainsOnceAvailable() async throws {
        let storage = try self.makeStorage("buffer-without-phone")
        let id = UUID()
        let directory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertFalse(watchSession.isReachable)
        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        let manifestState = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(manifestState, .transferring)
        let audioURL = storage.audioURL(directory: directory)
        let audioExists = await storage.fileWriter.fileExists(at: audioURL)
        XCTAssertTrue(audioExists)
        let audioSize = try await storage.fileWriter.fileSize(at: audioURL)
        XCTAssertGreaterThan(audioSize, 0)

        let phoneSession = MockWatchConnectivitySession()
        let stagingRoot = self.tempDirectory.appendingPathComponent("buffer-staging", isDirectory: true)
        let ledger = self.makeLedger("buffer-ledger")
        let receiver = try self.makeReceiver(
            session: phoneSession,
            stagingRoot: stagingRoot,
            ledger: ledger
        )
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("buffer-transfer", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: ledger,
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )
        defer { withExtendedLifetime(receiver) {} }

        XCTAssertEqual(ledger.lifetimeReceived, 0)
        XCTAssertTrue(try self.stagedEntryIDs(at: stagingRoot).isEmpty)

        watchSession.emitReachability(true)
        phoneSession.emitReachability(true)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])

        await drain.drain()
        var snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.sessionID, id)

        await drain.drain()
        snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
    }

    func testNeverDuplicateRestagesOnceAndReACKsDuplicate() async throws {
        let storage = try self.makeStorage("never-duplicate-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("never-duplicate-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)

        await self.cancelOutstandingAndRedrive(sender: sender, session: watchSession)
        XCTAssertEqual(watchSession.transferredFiles.count, 2)
        try await self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 2)

        watchSession.deliverUserInfo(try XCTUnwrap(phoneSession.transferredUserInfos.last))
        await self.settleConnectivityCallback()
        await self.waitForNoManifests(in: storage)

        let sourceDirectoryExists = await storage.fileWriter.fileExists(at: sourceDirectory)
        XCTAssertFalse(sourceDirectoryExists)
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
    }

    func testReachableACKUsesFastMessageAndDurableUserInfo() async throws {
        let storage = try self.makeStorage("reachable-ack-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("reachable-ack-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        phoneSession.emitReachability(true)
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.sentMessages.count, 1)
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.sentMessages[0], id: id)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)

        watchSession.deliverUserInfo(phoneSession.sentMessages[0])
        await self.settleConnectivityCallback()
        await self.waitForNoManifests(in: storage)

        let sourceDirectoryExists = await storage.fileWriter.fileExists(at: sourceDirectory)
        XCTAssertFalse(sourceDirectoryExists)
        let manifests = await self.catalogEntries(for: storage)
        XCTAssertEqual(manifests.count, 0)
    }

    func testUnreachableACKUsesOnlyDurableUserInfo() async throws {
        let storage = try self.makeStorage("unreachable-ack-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("unreachable-ack-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertTrue(phoneSession.sentMessages.isEmpty)
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)

        watchSession.deliverUserInfo(phoneSession.transferredUserInfos[0])
        await self.settleConnectivityCallback()
        await self.waitForNoManifests(in: storage)

        let sourceDirectoryExists = await storage.fileWriter.fileExists(at: sourceDirectory)
        XCTAssertFalse(sourceDirectoryExists)
        let manifests = await self.catalogEntries(for: storage)
        XCTAssertEqual(manifests.count, 0)
    }

    func testRelayACKTransfersDurableBeforeFastWhenReachable() async throws {
        let storage = try self.makeStorage("reachable-ack-order-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("reachable-ack-order-staging", isDirectory: true)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        phoneSession.emitReachability(true)
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.callLedger.count, 2)
        guard phoneSession.callLedger.count == 2 else { return }
        self.assertRecordedTransferUserInfo(phoneSession.callLedger[0], id: id)
        self.assertRecordedSendMessage(phoneSession.callLedger[1], id: id)
    }

    func testRelayACKUnreachableRecordsOnlyDurableTransfer() async throws {
        let storage = try self.makeStorage("unreachable-ack-order-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("unreachable-ack-order-staging", isDirectory: true)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.callLedger.count, 1)
        guard phoneSession.callLedger.count == 1 else { return }
        self.assertRecordedTransferUserInfo(phoneSession.callLedger[0], id: id)
    }

    func testFastAndDurableACKDeliveryIsIdempotent() async throws {
        let storage = try self.makeStorage("idempotent-ack-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("idempotent-ack-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        phoneSession.emitReachability(true)
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.sentMessages.count, 1)
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)

        watchSession.deliverUserInfo(phoneSession.sentMessages[0])
        await self.settleConnectivityCallback()
        watchSession.deliverUserInfo(phoneSession.transferredUserInfos[0])
        await self.settleConnectivityCallback()
        await self.waitForNoManifests(in: storage)

        let sourceDirectoryExists = await storage.fileWriter.fileExists(at: sourceDirectory)
        XCTAssertFalse(sourceDirectoryExists)
        let manifests = await self.catalogEntries(for: storage)
        XCTAssertEqual(manifests.count, 0)
    }

    func testSegmentStagedCallbackFiresForFreshAndDuplicateReceive() async throws {
        let storage = try self.makeStorage("staged-callback-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("staged-callback-staging", isDirectory: true)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(stagedIDs, [id])

        await self.cancelOutstandingAndRedrive(sender: sender, session: watchSession)
        try await self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(stagedIDs, [id, id])
    }

    func testReceiverInstrumentationTracksSuccessfulReceive() async throws {
        let storage = try self.makeStorage("instrumentation-success-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("instrumentation-success-staging", isDirectory: true)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let ledger = self.makeLedger("instrumentation-success-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        let invalidScratch = self.tempDirectory.appendingPathComponent("invalid-watchrelay")
        try Data("not a segment bundle".utf8).write(to: invalidScratch, options: .atomic)
        await receiver.receiveFile(invalidScratch, metadata: ["id": UUID().uuidString])
        XCTAssertNotNil(receiver.lastStagingError)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

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

    func testReceiverInstrumentationRefreshesDuplicateWithoutIncrementing() async throws {
        let storage = try self.makeStorage("instrumentation-duplicate-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("instrumentation-duplicate-staging", isDirectory: true)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let ledger = self.makeLedger("instrumentation-duplicate-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)
        let firstReceivedAt = try XCTUnwrap(receiver.lastReceivedAt)
        try await Task.sleep(for: .milliseconds(10))

        await self.cancelOutstandingAndRedrive(sender: sender, session: watchSession)
        try await self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(ledger.lifetimeReceived, 1)
        let duplicateReceivedAt = try XCTUnwrap(receiver.lastReceivedAt)
        XCTAssertGreaterThan(duplicateReceivedAt.timeIntervalSinceReferenceDate, firstReceivedAt.timeIntervalSinceReferenceDate)
    }

    func testReceiverInstrumentationTracksStagingFailure() async throws {
        let stagingRoot = self.tempDirectory.appendingPathComponent("instrumentation-failure-staging", isDirectory: true)
        let phoneSession = MockWatchConnectivitySession()
        let ledger = self.makeLedger("instrumentation-failure-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        let scratchURL = self.tempDirectory.appendingPathComponent("invalid-watchrelay")
        try Data("not a segment bundle".utf8).write(to: scratchURL, options: .atomic)
        defer { withExtendedLifetime(receiver) {} }

        await receiver.receiveFile(scratchURL, metadata: ["id": UUID().uuidString])

        XCTAssertEqual(ledger.lifetimeReceived, 0)
        XCTAssertNil(receiver.lastReceivedAt)
        XCTAssertNotNil(receiver.lastStagingError)
    }

    func testAC4TerminalDuplicateShortCircuitsHandedAndDroppedIDs() async throws {
        for terminalKind in ["handed", "dropped"] {
            let storage = try self.makeStorage("ac4-\(terminalKind)")
            let stagingRoot = self.tempDirectory.appendingPathComponent("ac4-\(terminalKind)-staging", isDirectory: true)
            let id = UUID()
            _ = try await self.writeSegment(storage: storage, id: id, index: 0)
            let watchSession = MockWatchConnectivitySession()
            let phoneSession = MockWatchConnectivitySession()
            let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
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
            await sender.requestDrain(trigger: .testDirect)
            try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

            XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
            self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)
            XCTAssertTrue(try self.stagedEntryIDs(at: stagingRoot).isEmpty)
            XCTAssertTrue(stagedIDs.isEmpty)
            XCTAssertNotNil(receiver.lastReceivedAt)
            XCTAssertEqual(ledger.lifetimeReceived, 1)
        }
    }

    func testAC5NonTerminalDuplicateReACKsAndRekicks() async throws {
        let storage = try self.makeStorage("ac5-nonterminal-duplicate")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac5-nonterminal-staging", isDirectory: true)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let ledger = self.makeLedger("ac5-nonterminal-ledger")
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)
        XCTAssertEqual(stagedIDs, [id])
        XCTAssertEqual(ledger.lifetimeReceived, 1)

        await self.cancelOutstandingAndRedrive(sender: sender, session: watchSession)
        try await self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(phoneSession.transferredUserInfos.count, 2)
        XCTAssertEqual(stagedIDs, [id, id])
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testAC5MissingNonTerminalStagingRestagesAndRekicks() async throws {
        let storage = try self.makeStorage("ac5-missing-staging")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac5-missing-staging-root", isDirectory: true)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let ledger = self.makeLedger("ac5-missing-ledger")
        ledger.recordReceived(id: id)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(stagedIDs, [id])
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testReplayACKsForCommittedSegmentsIncludesReceivedAndTerminalIDsWithoutStaging() async throws {
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

    func testAC8CorruptLedgerStillStagesAndACKs() async throws {
        let storage = try self.makeStorage("ac8-corrupt-ledger")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac8-corrupt-staging", isDirectory: true)
        let ledgerURL = self.tempDirectory
            .appendingPathComponent("ac8-corrupt-ledger-file", isDirectory: true)
            .appendingPathComponent("ledger.json", isDirectory: false)
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: ledgerURL)
        let ledger = WatchSegmentLedger(fileURL: ledgerURL)
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertNil(ledger.lastLedgerError)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testAC8PermanentLedgerWriteFailureStillStagesAndACKs() async throws {
        let storage = try self.makeStorage("ac8-write-failure-ledger")
        let stagingRoot = self.tempDirectory.appendingPathComponent("ac8-write-failure-staging", isDirectory: true)
        let blocker = self.tempDirectory.appendingPathComponent("ac8-blocker", isDirectory: false)
        try Data("blocker".utf8).write(to: blocker)
        let ledger = WatchSegmentLedger(fileURL: blocker.appendingPathComponent("ledger.json", isDirectory: false))
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot, ledger: ledger)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        try await self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)
        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertNotNil(ledger.lastLedgerError)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    func testAC1EnqueueOnceDoesNotDuplicateWhileOutstanding() async throws {
        let storage = try self.makeStorage("ac1-enqueue-once")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        XCTAssertEqual(watchSession.transferredFiles.first?.1["id"] as? String, id.uuidString)
        let state = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(state, .transferring)
    }

    func testAC2FullQueueHandoffDrainsAllQueuedAtOnce() async throws {
        let storage = try self.makeStorage("backlog-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("backlog-staging", isDirectory: true)
        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            _ = try await self.writeSegment(storage: storage, id: id, index: index)
        }
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        let receiver = try self.makeReceiver(session: phoneSession, stagingRoot: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(watchSession.transferredFiles.count, 3)
        XCTAssertEqual(Set(watchSession.transferredFiles.compactMap { $0.1["id"] as? String }), Set(ids.map(\.uuidString)))
        for id in ids {
            let state = try await self.manifestState(storage: storage, id: id)
            XCTAssertEqual(state, .transferring)
        }

        for index in watchSession.transferredFiles.indices {
            try await self.deliverTransfer(from: watchSession, index: index, to: phoneSession)
        }
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 3)
        for ack in phoneSession.transferredUserInfos.reversed() {
            watchSession.deliverUserInfo(ack)
            await self.settleConnectivityCallback()
        }

        await self.waitForNoManifests(in: storage)
        XCTAssertEqual(Set(try self.stagedEntryIDs(at: stagingRoot)), Set(ids.map(\.uuidString)))
        let manifests = await self.catalogEntries(for: storage)
        XCTAssertEqual(manifests.count, 0)
    }

    func testAC3DidFinishMatrixUpdatesOnlyExpectedStates() async throws {
        let storage = try self.makeStorage("ac3-finish-matrix")
        let watchSession = MockWatchConnectivitySession()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession, clock: { now })
        watchSession.activate()

        let successID = UUID()
        let successDirectory = try await self.writeSegment(storage: storage, id: successID, index: 0)
        await sender.requestDrain(trigger: .testDirect)
        let successBundleURL = sender.bundleURL(for: successID)
        let successBundleExists = await storage.fileWriter.fileExists(at: successBundleURL)
        XCTAssertTrue(successBundleExists)

        var stateChanges = 0
        sender.onStateChanged = { stateChanges += 1 }
        watchSession.finishTransfer(id: successID, failure: nil)
        await self.settleConnectivityCallback()
        await self.waitForManifestState(storage: storage, id: successID, expected: .delivered)

        let successState = try await self.manifestState(storage: storage, id: successID)
        XCTAssertEqual(successState, .delivered)
        let successManifest = try await self.manifest(storage: storage, id: successID)
        XCTAssertEqual(successManifest?.deliveredAt, now)
        let successDirectoryExists = await storage.fileWriter.fileExists(at: successDirectory)
        XCTAssertTrue(successDirectoryExists)
        let successBundleStillExists = await storage.fileWriter.fileExists(at: successBundleURL)
        XCTAssertTrue(successBundleStillExists)
        XCTAssertEqual(stateChanges, 1)

        let queuedSuccessID = UUID()
        _ = try await self.writeSegment(storage: storage, id: queuedSuccessID, index: 1)
        watchSession.finishTransfer(id: queuedSuccessID, failure: nil)
        await self.settleConnectivityCallback()
        await self.waitForManifestState(storage: storage, id: queuedSuccessID, expected: .delivered)
        let queuedSuccessState = try await self.manifestState(storage: storage, id: queuedSuccessID)
        XCTAssertEqual(queuedSuccessState, .delivered)
        let queuedSuccessManifest = try await self.manifest(storage: storage, id: queuedSuccessID)
        XCTAssertEqual(queuedSuccessManifest?.deliveredAt, now)
        XCTAssertEqual(stateChanges, 2)

        watchSession.finishTransfer(id: queuedSuccessID, failure: nil)
        await self.settleConnectivityCallback()
        let repeatedSuccessState = try await self.manifestState(storage: storage, id: queuedSuccessID)
        XCTAssertEqual(repeatedSuccessState, .delivered)
        XCTAssertEqual(stateChanges, 2)

        let failureID = UUID()
        _ = try await self.writeSegment(storage: storage, id: failureID, index: 2)
        await sender.requestDrain(trigger: .testDirect)
        let transferCountBeforeFailure = watchSession.transferredFiles.count
        watchSession.finishTransfer(id: failureID, failure: Self.transferFailure("network unavailable"))
        await self.settleConnectivityCallback()
        await self.waitForManifestState(storage: storage, id: failureID, expected: .queued)

        let failureState = try await self.manifestState(storage: storage, id: failureID)
        XCTAssertEqual(failureState, .queued)
        XCTAssertEqual(watchSession.transferredFiles.count, transferCountBeforeFailure)

        watchSession.finishTransfer(id: successID, failure: Self.transferFailure("late failure"))
        await self.settleConnectivityCallback()
        let lateSuccessState = try await self.manifestState(storage: storage, id: successID)
        XCTAssertEqual(lateSuccessState, .delivered)

        watchSession.finishTransfer(id: UUID(), failure: nil)
        await self.settleConnectivityCallback()
        watchSession.finishTransfer(id: UUID(), failure: Self.transferFailure("missing"))
        await self.settleConnectivityCallback()
        XCTAssertEqual(watchSession.transferredFiles.count, transferCountBeforeFailure)
    }

    func testRelayCallbackTailPreservesCompletionThenACKOrderWhileWriterIsHeld() async throws {
        let writer = BlockingRelayCallbackWriter()
        let storage = try self.makeStorage("relay-callback-tail", fileWriter: writer)
        let completionID = UUID()
        let acknowledgementID = UUID()
        _ = try await self.writeSegment(
            storage: storage,
            id: completionID,
            index: 0,
            state: .transferring
        )
        _ = try await self.writeSegment(
            storage: storage,
            id: acknowledgementID,
            index: 1,
            state: .delivered
        )
        let session = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session)

        await writer.armNextRead()
        session.finishTransfer(id: completionID, failure: nil)
        await writer.waitUntilReadEntered()

        session.deliverUserInfo(WatchRelayACK.userInfo(id: acknowledgementID))
        await self.settleConnectivityCallback()
        let readsWhileCompletionIsHeld = await writer.readCount()
        XCTAssertEqual(readsWhileCompletionIsHeld, 1)

        await writer.releaseRead()
        await self.drain(until: {
            let entries = await self.catalogEntries(for: storage)
            return entries.first { $0.manifest.id == completionID }?.manifest.state == .delivered
                && !entries.contains { $0.manifest.id == acknowledgementID }
        })

        let completionState = try await self.manifestState(storage: storage, id: completionID)
        XCTAssertEqual(completionState, .delivered)
        let acknowledgementManifest = try await self.manifest(storage: storage, id: acknowledgementID)
        XCTAssertNil(acknowledgementManifest)
        _ = sender
    }

    func testRequestDrainCoalescesQueuedFollowUpAndSchedulesAnotherAfterItStarts() async throws {
        let writer = BlockingRelayCallbackWriter()
        let storage = try self.makeStorage("single-flight-owner", fileWriter: writer)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 0)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )

        await writer.armNextRead()
        let passA = Task { await sender.requestDrain(trigger: .launchReconciliation) }
        await writer.waitUntilReadEntered()

        let queuedSegment = Task { await sender.requestDrain(trigger: .segmentFinalization) }
        await Task.yield()
        let queuedActivation = Task { await sender.requestDrain(trigger: .connectivityActivation) }
        await Task.yield()
        let queuedReachability = Task { await sender.requestDrain(trigger: .connectivityReachability) }
        await Task.yield()
        let queuedACK = Task { await sender.requestDrain(trigger: .durableACK) }
        await self.drain(until: {
            sink.events.filter { $0.kind == .begin && $0.boundary == .relayDrainRequest }.count == 5
        })

        // This arms B before A is released. Requests above merge while B is
        // queued; the durable ACK is the latest retained trigger.
        await writer.armNextRead()
        await writer.releaseRead()
        await writer.waitUntilReadEntered()

        let passC = Task { await sender.requestDrain(trigger: .testDirect) }
        await Task.yield()
        await writer.releaseRead()

        await passA.value
        await queuedSegment.value
        await queuedActivation.value
        await queuedReachability.value
        await queuedACK.value
        await passC.value

        let passTriggers = sink.events.compactMap { event -> RelayTrigger? in
            guard event.kind == .begin, event.boundary == .relayDrain else { return nil }
            return event.fields.trigger
        }
        XCTAssertEqual(passTriggers, [.launchReconciliation, .durableACK, .testDirect])
        XCTAssertEqual(
            sink.events.filter { $0.kind == .begin && $0.boundary == .relayDrainRequest }.count,
            6
        )
    }

    func testAC4DeliveredWithoutTimestampStampsAndDoesNotRetransfer() async throws {
        let storage = try self.makeStorage("ac4-delivered-nil")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .delivered)
        let watchSession = MockWatchConnectivitySession()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession, clock: { now })
        let bundleURL = sender.bundleURL(for: id)
        try FileManager.default.createDirectory(at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("existing bundle".utf8)
        try marker.write(to: bundleURL, options: .atomic)

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertTrue(watchSession.transferredFiles.isEmpty)
        let state = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(state, .delivered)
        let manifest = try await self.manifest(storage: storage, id: id)
        XCTAssertEqual(manifest?.deliveredAt, now)
        XCTAssertEqual(try Data(contentsOf: bundleURL), marker)
    }

    func testAC4DeliveredWithinDeadlineDoesNotRetransfer() async throws {
        let storage = try self.makeStorage("ac4-delivered-fresh")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deliveredAt = now.addingTimeInterval(-60)
        _ = try await self.writeSegment(
            storage: storage,
            id: id,
            index: 0,
            state: .delivered,
            deliveredAt: deliveredAt
        )
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession, clock: { now })
        let bundleURL = sender.bundleURL(for: id)
        try FileManager.default.createDirectory(at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("existing bundle".utf8)
        try marker.write(to: bundleURL, options: .atomic)

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertTrue(watchSession.transferredFiles.isEmpty)
        let state = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(state, .delivered)
        let manifest = try await self.manifest(storage: storage, id: id)
        XCTAssertEqual(manifest?.deliveredAt, deliveredAt)
        XCTAssertEqual(try Data(contentsOf: bundleURL), marker)
    }

    func testAC4DeliveredPastDeadlineRequeuesAndRetransfers() async throws {
        let storage = try self.makeStorage("ac4-delivered-expired")
        let id = UUID()
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try await self.writeSegment(
            storage: storage,
            id: id,
            index: 0,
            state: .delivered,
            deliveredAt: now.addingTimeInterval(-900)
        )
        let watchSession = MockWatchConnectivitySession()
        watchSession.isReachable = true
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession, clock: { now })

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)

        // Advance 900s within the established hear-back window
        now = now.addingTimeInterval(900)
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        XCTAssertEqual(watchSession.transferredFiles.first?.1["id"] as? String, id.uuidString)
        var state = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(state, .transferring)
        let manifest = try await self.manifest(storage: storage, id: id)
        XCTAssertNil(manifest?.deliveredAt)

        // Complete the transfer to .delivered with a fresh deliveredAt
        let storageActor = self.storageActor(for: storage)
        let currentEntry = (await self.catalogEntries(for: storage)).first!
        var deliveredManifest = currentEntry.manifest
        deliveredManifest.state = .delivered
        deliveredManifest.deliveredAt = now
        _ = try await storageActor.writeManifest(deliveredManifest, ensuringDirectory: false, transactionClass: .captureSafety)
        watchSession.finishTransfer(id: id, failure: nil)
        await self.settleConnectivityCallback()

        // Jump another >= 900s reachable
        now = now.addingTimeInterval(900)
        await sender.requestDrain(trigger: .testDirect)

        // Expires again and retransfers
        XCTAssertEqual(watchSession.transferredFiles.count, 2)
        state = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(state, .transferring)
    }

    func testAC5FailureRetryViaNaturalDrainRequeuesAndRetries() async throws {
        let storage = try self.makeStorage("ac5-failure-retry")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(watchSession.transferredFiles.count, 1)

        watchSession.finishTransfer(id: id, failure: Self.transferFailure("first failure"))
        await self.settleConnectivityCallback()
        await self.waitForManifestState(storage: storage, id: id, expected: .queued)
        let firstFailureState = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(firstFailureState, .queued)
        XCTAssertEqual(watchSession.transferredFiles.count, 1)

        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(watchSession.transferredFiles.count, 2)
        watchSession.finishTransfer(id: id, failure: Self.transferFailure("second failure"))
        await self.settleConnectivityCallback()
        await self.waitForManifestState(storage: storage, id: id, expected: .queued)

        let secondFailureState = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(secondFailureState, .queued)
    }

    func testDrainContinuesWithHealthySiblingAfterSegmentWriteFailure() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-segment-isolation", fileWriter: writer)
        let failedID = UUID()
        let healthyID = UUID()
        _ = try await self.writeSegment(storage: storage, id: failedID, index: 0)
        _ = try await self.writeSegment(storage: storage, id: healthyID, index: 1)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        writer.failNextWriteData(at: sender.bundleURL(for: failedID))
        session.activate()

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 1)
        XCTAssertEqual(session.transferredFiles[0].1["id"] as? String, healthyID.uuidString)
        let failedState = try await self.manifestState(storage: storage, id: failedID)
        XCTAssertEqual(failedState, .transferring)
        let healthyState = try await self.manifestState(storage: storage, id: healthyID)
        XCTAssertEqual(healthyState, .transferring)
        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .partial)
        XCTAssertGreaterThan(drain.fields.failureCount ?? 0, 0)
    }

    func testDrainAllHealthySiblingSegmentsReportsCompleted() async throws {
        let storage = try self.makeStorage("drain-all-healthy")
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 0)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 1)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 2)
        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .completed)
        XCTAssertEqual(drain.fields.failureCount, 0)
    }

    func testDrainEmptyActivatedQueueReconcilesAndCancelsOrphan() async throws {
        let storage = try self.makeStorage("drain-empty-activated")
        try await storage.fileWriter.createDirectory(at: storage.rootURL)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let diagnostics = self.storageActor(for: storage)
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: diagnostics,
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        let orphanID = UUID()
        session.seedOutstandingTransfer(id: orphanID)
        session.activate()

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.cancelledSegmentIDs, [orphanID])
        let diagnosticsSummary = await diagnostics.readDiagnosticsSummary()
        XCTAssertNotNil(diagnosticsSummary.value?.lastQueueReconciliationObservation)
        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .completed)
        XCTAssertEqual(drain.fields.activation, .activated)
        XCTAssertEqual(drain.fields.entryWorkload, .empty)
        XCTAssertEqual(drain.fields.refreshedWorkload, .empty)
        XCTAssertEqual(drain.fields.transferCandidateCount, 0)
    }

    func testDrainDoesNotCancelUnknownOutstandingTransferWhenCatalogIsPartial() async throws {
        let storage = try self.makeStorage("drain-partial-catalog")
        let healthyID = UUID()
        _ = try await self.writeSegment(storage: storage, id: healthyID, index: 0)
        let malformedDirectory = storage.rootURL
            .appendingPathComponent("20240416", isDirectory: true)
            .appendingPathComponent("120500_60", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storage.manifestURL(directory: malformedDirectory))
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        let unknownID = UUID()
        session.seedOutstandingTransfer(id: unknownID)
        session.activate()

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.map { $0.1["id"] as? String }, [healthyID.uuidString])
        XCTAssertFalse(session.cancelledSegmentIDs.contains(unknownID))
        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .partial)
        XCTAssertEqual(drain.fields.entryWorkload, .unknown)
        XCTAssertNil(drain.fields.transferCandidateCount)
    }

    func testDrainFirstManifestScanFailureReportsFailedUnknownEntryWorkload() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-first-scan-failure", fileWriter: writer)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()
        try await writer.createDirectory(at: storage.rootURL)
        writer.failContents(atOrdinal: writer.currentContentsCallCount + 1)

        await sender.requestDrain(trigger: .testDirect)

        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .failed)
        XCTAssertEqual(drain.fields.activation, .activated)
        XCTAssertEqual(drain.fields.entryWorkload, .unknown)
        XCTAssertEqual(drain.fields.refreshedWorkload, .empty)
        XCTAssertEqual(drain.fields.transferCandidateCount, 0)
        XCTAssertEqual(drain.fields.failureCount, 0)
    }

    func testDrainRefreshedManifestScanFailureKeepsKnownEntryWorkload() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-refreshed-scan-failure", fileWriter: writer)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 0)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 1, state: .safeToDelete)
        let before = writer.currentContentsCallCount
        _ = await self.catalogEntries(for: storage)
        let callsPerScan = writer.currentContentsCallCount - before
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()
        writer.failContents(atOrdinal: writer.currentContentsCallCount + callsPerScan + 1)

        await sender.requestDrain(trigger: .testDirect)

        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.entryWorkload, .small)
        if drain.fields.refreshedWorkload == .unknown {
            XCTAssertEqual(drain.fields.result, .failed)
            XCTAssertNil(drain.fields.transferCandidateCount)
        } else {
            XCTAssertEqual(drain.fields.result, .completed)
            XCTAssertEqual(drain.fields.refreshedWorkload, .small)
            XCTAssertEqual(drain.fields.transferCandidateCount, 1)
        }
        XCTAssertEqual(drain.fields.failureCount, 0)
    }

    func testDrainHealthyQueuedCatalogReusesCleanupPopulationWithoutSecondScan() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-healthy-reuse", fileWriter: writer)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 0)
        let before = writer.currentContentsCallCount
        _ = await self.catalogEntries(for: storage)
        let callsPerScan = writer.currentContentsCallCount - before
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()
        writer.failContents(atOrdinal: writer.currentContentsCallCount + callsPerScan + 1)

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 1)
        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .completed)
        XCTAssertEqual(drain.fields.entryWorkload, .small)
        XCTAssertEqual(drain.fields.refreshedWorkload, .small)
        XCTAssertEqual(drain.fields.transferCandidateCount, 1)
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .relayQueueReconciliation && $0.fields.result == .cached
        })
    }

    func testDrainUnconditionalSecondScanIsGoneOnHealthyCompleteCatalog() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-no-unconditional-second-scan", fileWriter: writer)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 0)
        let before = writer.currentContentsCallCount
        _ = await self.catalogEntries(for: storage)
        let callsPerScan = writer.currentContentsCallCount - before
        let session = MockWatchConnectivitySession()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session
        )
        session.activate()
        writer.failContents(atOrdinal: writer.currentContentsCallCount + callsPerScan + 1)

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 1)
    }

    func testDrainCountsCleanupFailureBeforeFatalRefreshedScanFailure() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-cleanup-then-scan-failure", fileWriter: writer)
        let directory = try await self.writeSegment(storage: storage, id: UUID(), index: 0, state: .safeToDelete)
        let before = writer.currentContentsCallCount
        _ = await self.catalogEntries(for: storage)
        let callsPerScan = writer.currentContentsCallCount - before
        writer.failRemoveItem(at: directory)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()
        writer.failContents(atOrdinal: writer.currentContentsCallCount + callsPerScan + 1)

        await sender.requestDrain(trigger: .testDirect)

        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .partial)
        XCTAssertGreaterThanOrEqual(drain.fields.failureCount ?? 0, 1)
    }

    func testDrainMixedRefreshedPopulationCountsOnlyTransferCandidates() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-mixed-refreshed", fileWriter: writer)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 0, state: .queued)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 1, state: .transferring)
        _ = try await self.writeSegment(storage: storage, id: UUID(), index: 2, state: .delivered)
        let acked = try await self.writeSegment(storage: storage, id: UUID(), index: 3, state: .acked)
        let safe = try await self.writeSegment(storage: storage, id: UUID(), index: 4, state: .safeToDelete)
        writer.failRemoveItem(at: acked)
        writer.failRemoveItem(at: safe)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()

        await sender.requestDrain(trigger: .testDirect)

        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.transferCandidateCount, 2)
    }

    func testDrainCleanupFailureBeforeInactiveGuardRemainsPartial() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-inactive-cleanup-failure", fileWriter: writer)
        let directory = try await self.writeSegment(storage: storage, id: UUID(), index: 0, state: .safeToDelete)
        writer.failRemoveItem(at: directory)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )

        await sender.requestDrain(trigger: .testDirect)

        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .partial)
        XCTAssertEqual(drain.fields.activation, .notActivated)
        XCTAssertEqual(drain.fields.entryWorkload, .small)
        XCTAssertEqual(drain.fields.refreshedWorkload, .notSampled)
        XCTAssertNil(drain.fields.transferCandidateCount)
        XCTAssertGreaterThan(drain.fields.failureCount ?? 0, 0)
    }

    func testDrainDiagnosticsPersistenceFailureReportsPartialAndEnqueuesTransfer() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("drain-diagnostics-persistence-failure", fileWriter: writer)
        let id = UUID()
        let directory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let diagnostics = self.storageActor(for: storage)
        writer.failNextWriteData(at: WatchRelayDiagnosticsFiles.sidecarURL(directoryURL: directory))
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: diagnostics,
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 1)
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .relayDiagnosticsPersistence && $0.fields.result == .failed
        })
        let drain = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drain.fields.result, .partial)
    }

    func testDurableACKForwardsTriggerToRelayDrainInterval() async throws {
        let storage = try self.makeStorage("durable-ack-trigger")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .delivered)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )

        session.deliverUserInfo(WatchRelayACK.userInfo(id: id))
        await self.settleConnectivityCallback()

        await self.drain(until: {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .relayDrain && $0.fields.trigger == .durableACK
            }
        })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .relayDrain && $0.fields.trigger == .durableACK
        })
        _ = sender
    }

    func testAC6BidirectionalReconcileHandlesOutstandingSnapshots() async throws {
        let storageA = try self.makeStorage("ac6-absent")
        let absentID = UUID()
        _ = try await self.writeSegment(storage: storageA, id: absentID, index: 0, state: .transferring)
        let sessionA = MockWatchConnectivitySession()
        let senderA = WatchRelaySender(paths: storageA.paths, storageActor: self.storageActor(for: storageA), session: sessionA)
        sessionA.activate()
        await senderA.requestDrain(trigger: .testDirect)
        await senderA.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sessionA.transferredFiles.count, 1)
        let absentState = try await self.manifestState(storage: storageA, id: absentID)
        XCTAssertEqual(absentState, .transferring)

        let storageB = try self.makeStorage("ac6-present")
        let presentID = UUID()
        _ = try await self.writeSegment(storage: storageB, id: presentID, index: 0, state: .transferring)
        let sessionB = MockWatchConnectivitySession()
        sessionB.seedOutstandingTransfer(id: presentID)
        let senderB = WatchRelaySender(paths: storageB.paths, storageActor: self.storageActor(for: storageB), session: sessionB)
        sessionB.activate()
        await senderB.requestDrain(trigger: .testDirect)
        XCTAssertTrue(sessionB.transferredFiles.isEmpty)
        XCTAssertTrue(sessionB.cancelledSegmentIDs.isEmpty)
        let presentState = try await self.manifestState(storage: storageB, id: presentID)
        XCTAssertEqual(presentState, .transferring)

        let storageC = try self.makeStorage("ac6-adopt")
        let adoptID = UUID()
        _ = try await self.writeSegment(storage: storageC, id: adoptID, index: 0)
        let sessionC = MockWatchConnectivitySession()
        sessionC.seedOutstandingTransfer(id: adoptID)
        let senderC = WatchRelaySender(paths: storageC.paths, storageActor: self.storageActor(for: storageC), session: sessionC)
        sessionC.activate()
        await senderC.requestDrain(trigger: .testDirect)
        XCTAssertTrue(sessionC.transferredFiles.isEmpty)
        XCTAssertEqual(sessionC.cancelledSegmentIDs, [])
        let adoptState = try await self.manifestState(storage: storageC, id: adoptID)
        XCTAssertEqual(adoptState, .transferring)

        let storageD = try self.makeStorage("ac6-duplicates")
        let duplicateID = UUID()
        let duplicateDirectory = try await self.writeSegment(storage: storageD, id: duplicateID, index: 0)
        let sessionD = MockWatchConnectivitySession()
        sessionD.seedOutstandingTransfer(id: duplicateID)
        sessionD.seedOutstandingTransfer(id: duplicateID)
        let senderD = WatchRelaySender(paths: storageD.paths, storageActor: self.storageActor(for: storageD), session: sessionD)
        sessionD.activate()
        await senderD.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sessionD.cancelledSegmentIDs, [duplicateID])
        XCTAssertEqual(sessionD.outstandingFileTransfers.map(\.snapshot.segmentID), [duplicateID])
        let duplicateDirectoryExists = await storageD.fileWriter.fileExists(at: duplicateDirectory)
        XCTAssertTrue(duplicateDirectoryExists)

        let storageE = try self.makeStorage("ac6-orphans")
        let deliveredID = UUID()
        let deliveredDirectory = try await self.writeSegment(storage: storageE, id: deliveredID, index: 0, state: .delivered)
        let missingID = UUID()
        let sessionE = MockWatchConnectivitySession()
        sessionE.seedOutstandingTransfer(id: nil)
        sessionE.seedOutstandingTransfer(id: missingID)
        sessionE.seedOutstandingTransfer(id: deliveredID)
        let senderE = WatchRelaySender(paths: storageE.paths, storageActor: self.storageActor(for: storageE), session: sessionE)
        sessionE.activate()
        await senderE.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sessionE.cancelledSegmentIDs.count, 3)
        XCTAssertTrue(sessionE.cancelledSegmentIDs.contains { $0 == nil })
        XCTAssertTrue(sessionE.cancelledSegmentIDs.contains(missingID))
        XCTAssertTrue(sessionE.cancelledSegmentIDs.contains(deliveredID))
        let deliveredDirectoryExists = await storageE.fileWriter.fileExists(at: deliveredDirectory)
        XCTAssertTrue(deliveredDirectoryExists)
        XCTAssertTrue(sessionE.transferredFiles.isEmpty)
    }

    func testAC7ActivationGateAndExactlyOnce() async throws {
        let storage = try self.makeStorage("ac7-activation")
        let queuedID = UUID()
        let transferringID = UUID()
        _ = try await self.writeSegment(storage: storage, id: queuedID, index: 0)
        _ = try await self.writeSegment(storage: storage, id: transferringID, index: 1, state: .transferring)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertTrue(watchSession.transferredFiles.isEmpty)
        XCTAssertTrue(watchSession.cancelledSegmentIDs.isEmpty)
        let queuedState = try await self.manifestState(storage: storage, id: queuedID)
        XCTAssertEqual(queuedState, .queued)
        let transferringState = try await self.manifestState(storage: storage, id: transferringID)
        XCTAssertEqual(transferringState, .transferring)

        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(watchSession.transferredFiles.count, 2)
        XCTAssertEqual(Set(watchSession.transferredFiles.compactMap { $0.1["id"] as? String }), Set([queuedID.uuidString, transferringID.uuidString]))
        let queuedTransferState = try await self.manifestState(storage: storage, id: queuedID)
        XCTAssertEqual(queuedTransferState, .transferring)
        let transferringTransferState = try await self.manifestState(storage: storage, id: transferringID)
        XCTAssertEqual(transferringTransferState, .transferring)
    }

    func testDrainSignpostKeepsInactiveEmptyMaintenanceCompleted() async throws {
        let storage = try self.makeStorage("drain-signpost-inactive")
        try await storage.fileWriter.createDirectory(at: storage.rootURL)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )

        await sender.requestDrain(trigger: .testDirect)

        let outer = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(outer.boundary, .relayDrain)
        XCTAssertEqual(
            outer.fields,
            WatchSignpostFields(
                trigger: .testDirect,
                result: .completed,
                activation: .notActivated,
                entryWorkload: .empty,
                refreshedWorkload: .notSampled,
                failureCount: 0
            )
        )
        XCTAssertEqual(sink.openInvocationCount, 0)
    }

    func testAC8ACKOnDeliveredDeletesAndLateFinishNoops() async throws {
        let storage = try self.makeStorage("ac8-ack-delivered")
        let id = UUID()
        let directory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: watchSession)
        watchSession.activate()
        await sender.requestDrain(trigger: .testDirect)
        let bundleURL = sender.bundleURL(for: id)
        let bundleExists = await storage.fileWriter.fileExists(at: bundleURL)
        XCTAssertTrue(bundleExists)

        watchSession.finishTransfer(id: id, failure: nil)
        await self.settleConnectivityCallback()
        await self.waitForManifestState(storage: storage, id: id, expected: .delivered)
        let deliveredState = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(deliveredState, .delivered)

        watchSession.deliverUserInfo(WatchRelayACK.userInfo(id: id))
        await self.settleConnectivityCallback()
        await self.drain(until: {
            let manifests = await self.catalogEntries(for: storage)
            let bundleExists = await storage.fileWriter.fileExists(at: bundleURL)
            return manifests.isEmpty && !bundleExists
        })
        let directoryExists = await storage.fileWriter.fileExists(at: directory)
        XCTAssertFalse(directoryExists)
        let bundleStillExists = await storage.fileWriter.fileExists(at: bundleURL)
        XCTAssertFalse(bundleStillExists)
        let manifests = await self.catalogEntries(for: storage)
        XCTAssertEqual(manifests.count, 0)

        let transferCount = watchSession.transferredFiles.count
        watchSession.finishTransfer(id: id, failure: nil)
        await self.settleConnectivityCallback()
        watchSession.finishTransfer(id: id, failure: Self.transferFailure("late failure"))
        await self.settleConnectivityCallback()
        XCTAssertEqual(watchSession.transferredFiles.count, transferCount)
    }

    func testDrainUsesOneAdversarialOutstandingCaptureAndKeepsFirstDuplicate() async throws {
        let storage = try self.makeStorage("single-capture")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let session = AdversarialOutstandingSession(segmentID: id)
        let store = self.storageActor(for: storage)
        let sender = WatchRelaySender(paths: storage.paths, storageActor: store, session: session)

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.outstandingReadCount, 1)
        XCTAssertEqual(session.cancelledRuntimeTokens, [1])
        let summaryAvailability = await store.readDiagnosticsSummary()
        let reconciliation = try XCTUnwrap(summaryAvailability.value?.lastQueueReconciliationObservation)
        XCTAssertEqual(reconciliation.observedFileTransferCount, 2)
        XCTAssertEqual(reconciliation.counts.duplicate, 1)
        XCTAssertEqual(reconciliation.counts.orphaned, 0)
    }

    func testTransfersUseDistinctAttemptIDsWithFrozenClock() async throws {
        let storage = try self.makeStorage("distinct-attempts")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let session = MockWatchConnectivitySession()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session, clock: { now })
        session.activate()

        await sender.requestDrain(trigger: .testDirect)
        await self.cancelOutstandingAndRedrive(sender: sender, session: session)

        XCTAssertEqual(session.transferredFiles.count, 2)
        let first = session.transferredFiles[0].1
        let second = session.transferredFiles[1].1
        XCTAssertEqual(first["generation"] as? Int, 0)
        XCTAssertEqual(second["generation"] as? Int, 0)
        XCTAssertEqual(first["attempt_started_at"] as? String, second["attempt_started_at"] as? String)
        XCTAssertNotEqual(first["attempt_id"] as? String, second["attempt_id"] as? String)
    }

    func testReversedTaggedCompletionsRemainSegmentLevelOnly() async throws {
        let storage = try self.makeStorage("reversed-completions")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .transferring)
        let firstAttempt = UUID()
        let secondAttempt = UUID()
        let session = MockWatchConnectivitySession()
        session.seedOutstandingTransfer(id: id, generation: 0, attemptID: firstAttempt)
        session.seedOutstandingTransfer(id: id, generation: 0, attemptID: secondAttempt)
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session)

        session.finishTransfer(attemptID: secondAttempt, failure: nil)
        await self.settleConnectivityCallback()
        await self.waitForManifestState(storage: storage, id: id, expected: .delivered)
        let deliveredState = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(deliveredState, .delivered)

        session.finishTransfer(attemptID: firstAttempt, failure: Self.transferFailure("late failure"))
        await self.settleConnectivityCallback()
        let lateCompletionState = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(lateCompletionState, .delivered)
    }

    func testUnchangedRetryReportsCachedBundleWriteSignpost() async throws {
        let storage = try self.makeStorage("reuse-cached-signpost")
        let id = UUID()
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(session.transferredFiles.count, 1)
        XCTAssertTrue(sink.events.contains {
            $0.boundary == .relayBundleWrite && $0.kind == .end && $0.fields.result == .completed
        })

        let retrySession = MockWatchConnectivitySession()
        let retrySink = WatchSignpostTestSink()
        let retrySender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: retrySession,
            signposter: WatchSignposter(sink: retrySink)
        )
        retrySession.activate()
        await retrySender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(retrySession.transferredFiles.count, 1)
        XCTAssertTrue(retrySink.events.contains {
            $0.boundary == .relayBundleWrite && $0.kind == .end && $0.fields.result == .cached
        })
        XCTAssertNotEqual(
            session.transferredFiles[0].1["attempt_id"] as? String,
            retrySession.transferredFiles[0].1["attempt_id"] as? String
        )
    }

    func testReceiptWriteFailureEnqueuesPartialAndNextAttemptRebuilds() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("receipt-write-failure", fileWriter: writer)
        let id = UUID()
        let directory = try await self.writeSegment(storage: storage, id: id, index: 0)
        let receiptURL = directory.appendingPathComponent(WatchRelayBundleReceipt.filename)
        writer.failNextWriteData(at: receiptURL)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        session.activate()
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(session.transferredFiles.count, 1)
        XCTAssertTrue(sink.events.contains {
            $0.boundary == .relayBundleWrite && $0.kind == .end && $0.fields.result == .partial
        })
        let receiptExists = await writer.fileExists(at: receiptURL)
        XCTAssertFalse(receiptExists)

        writer.clearReadFailure(at: receiptURL)
        let retrySession = MockWatchConnectivitySession()
        let retrySender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: retrySession
        )
        retrySession.activate()
        await retrySender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(retrySession.transferredFiles.count, 1)
        let receiptExistsAfterRetry = await writer.fileExists(at: receiptURL)
        XCTAssertTrue(receiptExistsAfterRetry)
    }

    func testAttemptRecordWriteFailureFallsBackToLegacyTransferAndContinuesDrain() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try self.makeStorage("attempt-write-failure", fileWriter: writer)
        let firstID = UUID()
        let secondID = UUID()
        let firstDirectory = try await self.writeSegment(storage: storage, id: firstID, index: 0)
        _ = try await self.writeSegment(storage: storage, id: secondID, index: 1)
        let session = MockWatchConnectivitySession()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: session,
            signposter: WatchSignposter(sink: sink)
        )
        writer.failNextWriteData(at: firstDirectory.appendingPathComponent(WatchRelayAttemptRecord.filename))
        session.activate()

        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 2)
        XCTAssertNil(session.transferredFiles[0].1["generation"])
        XCTAssertNil(session.transferredFiles[0].1["attempt_id"])
        XCTAssertNil(session.transferredFiles[0].1["attempt_started_at"])
        let attemptRecordExists = await writer.fileExists(at: firstDirectory.appendingPathComponent(WatchRelayAttemptRecord.filename))
        XCTAssertFalse(attemptRecordExists)
        XCTAssertEqual(session.transferredFiles[1].1["generation"] as? Int, 0)
        XCTAssertTrue(sink.events.contains {
            $0.boundary == .relayAttemptPersistence && $0.kind == .end && $0.fields.result == .failed
        })
        XCTAssertEqual(sink.events.last?.fields.result, .partial)
    }

    func testRelayDurablyWritesBundleBeforeTransferFile() async throws {
        let id = UUID()
        let rootURL = self.tempDirectory.appendingPathComponent("bundle-before-transfer", isDirectory: true)
        let bundleURL = rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
        let probe = RelayTransferOrderProbe()
        let writer = RelayBundleOrderingWriter(bundleURL: bundleURL) {
            probe.bundleWriteCompleted = true
        }
        let storage = try WatchCaptureTestStorage(rootURL: rootURL, fileWriter: writer)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0)
        let session = MockWatchConnectivitySession()
        session.onTransferFile = { [probe] _, _ in
            probe.transferObservedBundleWrite = probe.bundleWriteCompleted
        }
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session)

        session.activate()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 1)
        XCTAssertTrue(probe.bundleWriteCompleted)
        XCTAssertTrue(probe.transferObservedBundleWrite)
    }

    func testOwnerPresentationRelayStrings() async {
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

        let abandoned = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, abandonedCount: 1)
        XCTAssertEqual(abandoned.headline, "never reached your iphone")
        XCTAssertEqual(abandoned.countsLine, "1 never reached your iphone")
        XCTAssertNil(abandoned.attentionLine)

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

    func testDeliveredDeadlineExpiresOnlyInHearBackWindow() async throws {
        let storage = try self.makeStorage("delivered-hearback-window")
        let id = UUID()
        var now = Date(timeIntervalSince1970: 1_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .delivered, deliveredAt: now)
        let watchSession = MockWatchConnectivitySession()
        watchSession.isReachable = false
        watchSession.activate()

        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: watchSession,
            clock: { now }
        )

        // Advance clock by 1000s while unreachable -> should NOT expire
        now = now.addingTimeInterval(1000)
        await sender.requestDrain(trigger: .testDirect)
        var entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .delivered)

        // Now become reachable -> enters hear-back window at new now
        watchSession.isReachable = true
        await sender.requestDrain(trigger: .connectivityReachability)
        entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .delivered)

        // Advance clock within window (< 900s) -> still delivered
        now = now.addingTimeInterval(500)
        await sender.requestDrain(trigger: .testDirect)
        entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .delivered)

        // Advance past 900s in window -> re-queues to .queued
        now = now.addingTimeInterval(450)
        await sender.requestDrain(trigger: .testDirect)
        entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .transferring) // promoted/transferred
    }

    func testStickyHearBackWindowAccumulatesAcrossSparsePasses() async throws {
        let storage = try self.makeStorage("sparse-hearback-window")
        let id = UUID()
        var now = Date(timeIntervalSince1970: 2_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .delivered, deliveredAt: now)
        let watchSession = MockWatchConnectivitySession()
        watchSession.isReachable = true
        watchSession.activate()

        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: watchSession,
            clock: { now }
        )

        // First pass sets windowStart = 2,000,000
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sender.hearBackWindowStart, now)

        // Sparse pass 500s later in same process -> keeps windowStart
        now = now.addingTimeInterval(500)
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sender.hearBackWindowStart, Date(timeIntervalSince1970: 2_000_000))

        // Sparse pass 450s later (total 950s since window start) -> re-queues
        now = now.addingTimeInterval(450)
        await sender.requestDrain(trigger: .testDirect)
        let entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .transferring)
    }

    func testProcessRestartContinuesFreshWindowAndRebasesStale() async throws {
        let storage = try self.makeStorage("process-restart-window")
        var now = Date(timeIntervalSince1970: 3_000_000)
        let watchSession = MockWatchConnectivitySession()
        watchSession.isReachable = true
        watchSession.activate()

        let sender1 = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: watchSession,
            clock: { now }
        )
        await sender1.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sender1.hearBackWindowStart, now)

        // Process restart 100s later (< 900s) -> continues existing window
        now = now.addingTimeInterval(100)
        let sender2 = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: watchSession,
            clock: { now }
        )
        await sender2.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sender2.hearBackWindowStart, Date(timeIntervalSince1970: 3_000_000))

        // Process restart 1000s later (>= 900s since last sample) -> rebases window start to now
        now = now.addingTimeInterval(1000)
        let sender3 = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: watchSession,
            clock: { now }
        )
        await sender3.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sender3.hearBackWindowStart, now)
    }

    func testRelayDeliveryCeilingConjunctionAbandonsAndPrunesAfterSevenDays() async throws {
        let storage = try self.makeStorage("ceiling-abandon-prune")
        let id = UUID()
        var now = Date(timeIntervalSince1970: 4_000_000)
        let directory = try await self.writeSegment(storage: storage, id: id, index: 0, state: .queued)
        let storageActor = self.storageActor(for: storage)

        // Set manifest attempt count = 8 and effort = 43200 (12 hours)
        var initialManifest = await storageActor.scanCatalog(transactionClass: .captureSafety).entries.first!.manifest
        initialManifest.relayDeliveryAttemptCount = 8
        initialManifest.relayDeliveryEffortSeconds = 43200
        _ = try await storageActor.writeManifest(initialManifest, ensuringDirectory: false, transactionClass: .captureSafety)

        let watchSession = MockWatchConnectivitySession()
        watchSession.isReachable = true
        watchSession.activate()

        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: storageActor,
            session: watchSession,
            clock: { now }
        )

        await sender.requestDrain(trigger: .testDirect)

        var entries = await self.catalogEntries(for: storage)
        let abandonedManifest = try XCTUnwrap(entries.first?.manifest)
        XCTAssertEqual(abandonedManifest.state, WatchSegmentState.abandoned)
        XCTAssertEqual(abandonedManifest.failureReason, "relayDeliveryCeiling")
        XCTAssertEqual(abandonedManifest.abandonedAt, now)

        // Payload files should be deleted, manifest preserved
        let audioExists = await storage.fileWriter.fileExists(at: storage.audioURL(directory: directory))
        let manifestExists = await storage.fileWriter.fileExists(at: storage.manifestURL(directory: directory))
        XCTAssertFalse(audioExists)
        XCTAssertTrue(manifestExists)

        // Advance 6 days -> still kept
        now = now.addingTimeInterval(6 * 86400)
        await sender.requestDrain(trigger: .testDirect)
        entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.count, 1)

        // Advance past 7 days -> pruned completely
        now = now.addingTimeInterval(2 * 86400)
        await sender.requestDrain(trigger: .testDirect)
        entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.count, 0)
    }

    func testDeliveredDeadlineDoesNotExpireOnFirstReconnectPass() async throws {
        let storage = try self.makeStorage("reconnect-pass-no-requeue")
        let id = UUID()
        var now = Date(timeIntervalSince1970: 1_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .delivered, deliveredAt: now.addingTimeInterval(-1000))
        let watchSession = MockWatchConnectivitySession()
        watchSession.isReachable = false
        watchSession.activate()

        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: watchSession,
            clock: { now }
        )

        // Drain while unreachable: deliveredAt > 900s ago, but unreachable -> state stays .delivered
        await sender.requestDrain(trigger: .testDirect)
        var entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .delivered)
        XCTAssertEqual(watchSession.transferredFiles.count, 0)

        // Reconnect via emitReachability(true) + requestDrain(.connectivityReachability)
        watchSession.emitReachability(true)
        await sender.requestDrain(trigger: .connectivityReachability)

        // THAT reconnect pass: no re-queue, transferredFiles still 0, no new bundle, no new attempt record
        entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .delivered)
        XCTAssertEqual(watchSession.transferredFiles.count, 0)
        let bundleExists = await storage.fileWriter.fileExists(at: sender.bundleURL(for: id))
        XCTAssertFalse(bundleExists)
    }

    func testStickyHearBackWindowAccumulatesAcrossSparsePassesWiderThanDeadline() async throws {
        let storage = try self.makeStorage("sparse-wider-than-deadline")
        let id = UUID()
        var now = Date(timeIntervalSince1970: 2_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .delivered, deliveredAt: now)
        let watchSession = MockWatchConnectivitySession()
        watchSession.isReachable = true
        watchSession.activate()

        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: self.storageActor(for: storage),
            session: watchSession,
            clock: { now }
        )

        // First pass sets windowStart = 2,000,000
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sender.hearBackWindowStart, now)
        XCTAssertEqual(watchSession.transferredFiles.count, 0)

        // Two reachable drains with >= 1800s between them in same process (2000s)
        now = now.addingTimeInterval(2000)
        await sender.requestDrain(trigger: .testDirect)

        // Lost ACK expires exactly once
        XCTAssertEqual(sender.hearBackWindowStart, Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        let entries = await self.catalogEntries(for: storage)
        XCTAssertEqual(entries.first?.manifest.state, .transferring)
    }

    func testLivenessStallNeverMovedOffZeroAndPartialThenStall() async throws {
        // Part A: never moved off zero cancels and redrives, then completes
        let storageA = try self.makeStorage("stall-never-moved")
        let idA = UUID()
        var nowA = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storageA, id: idA, index: 0, state: .queued)
        let sessionA = MockWatchConnectivitySession()
        sessionA.isReachable = true
        sessionA.activate()
        let senderA = WatchRelaySender(paths: storageA.paths, storageActor: self.storageActor(for: storageA), session: sessionA, clock: { nowA })

        await senderA.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sessionA.transferredFiles.count, 1)

        // Advance 30 minutes with fractionCompleted = 0
        nowA = nowA.addingTimeInterval(1800)
        await senderA.requestDrain(trigger: .testDirect)
        await self.settleConnectivityCallback()
        await senderA.requestDrain(trigger: .testDirect)

        XCTAssertTrue(sessionA.cancelledSegmentIDs.contains(idA))
        XCTAssertEqual(sessionA.transferredFiles.count, 2)

        // Complete the redrive
        sessionA.finishTransfer(id: idA, failure: nil)
        await self.settleConnectivityCallback()

        // Part B: partial progress then stall
        let storageB = try self.makeStorage("stall-partial-progress")
        let idB = UUID()
        var nowB = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storageB, id: idB, index: 0, state: .queued)
        let sessionB = MockWatchConnectivitySession()
        sessionB.isReachable = true
        sessionB.activate()
        let senderB = WatchRelaySender(paths: storageB.paths, storageActor: self.storageActor(for: storageB), session: sessionB, clock: { nowB })

        await senderB.requestDrain(trigger: .testDirect)
        XCTAssertEqual(sessionB.transferredFiles.count, 1)

        // Move progress to 0.5 at 10 minutes
        nowB = nowB.addingTimeInterval(600)
        sessionB.updateOutstandingProgress(segmentID: idB, completedUnitCount: 50, totalUnitCount: 100, fractionCompleted: 0.5)
        await senderB.requestDrain(trigger: .testDirect)
        XCTAssertFalse(sessionB.cancelledSegmentIDs.contains(idB))

        // Freeze progress for 30 minutes past the last progress
        nowB = nowB.addingTimeInterval(1800)
        await senderB.requestDrain(trigger: .testDirect)
        await self.settleConnectivityCallback()
        await senderB.requestDrain(trigger: .testDirect)

        XCTAssertTrue(sessionB.cancelledSegmentIDs.contains(idB))
        XCTAssertEqual(sessionB.transferredFiles.count, 2)

        // Part C: Healthy slow advancing is never cancelled
        let storageC = try self.makeStorage("stall-healthy-advancing")
        let idC = UUID()
        var nowC = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storageC, id: idC, index: 0, state: .queued)
        let sessionC = MockWatchConnectivitySession()
        sessionC.isReachable = true
        sessionC.activate()
        let senderC = WatchRelaySender(paths: storageC.paths, storageActor: self.storageActor(for: storageC), session: sessionC, clock: { nowC })

        await senderC.requestDrain(trigger: .testDirect)
        // Advance 20 minutes with progress increment
        nowC = nowC.addingTimeInterval(1200)
        sessionC.updateOutstandingProgress(segmentID: idC, completedUnitCount: 30, totalUnitCount: 100, fractionCompleted: 0.3)
        await senderC.requestDrain(trigger: .testDirect)
        XCTAssertFalse(sessionC.cancelledSegmentIDs.contains(idC))

        // Advance another 20 minutes with progress increment
        nowC = nowC.addingTimeInterval(1200)
        sessionC.updateOutstandingProgress(segmentID: idC, completedUnitCount: 60, totalUnitCount: 100, fractionCompleted: 0.6)
        await senderC.requestDrain(trigger: .testDirect)
        XCTAssertFalse(sessionC.cancelledSegmentIDs.contains(idC))

        // Part D: 1.5-day (36 hours / 129600s) zero-progress fires stall cancel
        let storageD = try self.makeStorage("stall-day-and-a-half")
        let idD = UUID()
        var nowD = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storageD, id: idD, index: 0, state: .queued)
        let sessionD = MockWatchConnectivitySession()
        sessionD.isReachable = true
        sessionD.activate()
        let senderD = WatchRelaySender(paths: storageD.paths, storageActor: self.storageActor(for: storageD), session: sessionD, clock: { nowD })

        await senderD.requestDrain(trigger: .testDirect)
        nowD = nowD.addingTimeInterval(129_600) // 1.5 days
        await senderD.requestDrain(trigger: .testDirect)
        await self.settleConnectivityCallback()
        XCTAssertTrue(sessionD.cancelledSegmentIDs.contains(idD))
    }

    func testMissingAttemptMetadataCancelsAndRedrives() async throws {
        let storage = try self.makeStorage("missing-attempt")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .transferring)
        let session = MockWatchConnectivitySession()
        session.isReachable = true
        session.activate()

        session.seedOutstandingTransfer(
            id: id,
            idState: .parseable,
            attemptID: nil,
            attemptIDState: .missing,
            attemptStartedAt: nil
        )

        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session, clock: { now })
        await sender.requestDrain(trigger: .testDirect)
        await self.settleConnectivityCallback()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertTrue(session.cancelledSegmentIDs.contains(id))
        XCTAssertEqual(session.transferredFiles.count, 1)
        let metadata = session.transferredFiles.first?.1
        XCTAssertNotNil(UUID(uuidString: metadata?["attempt_id"] as? String ?? ""))
    }

    func testUnparseableAttemptMetadataCancelsAndRedrives() async throws {
        let storage = try self.makeStorage("unparseable-attempt")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .transferring)
        let session = MockWatchConnectivitySession()
        session.isReachable = true
        session.activate()

        session.seedOutstandingTransfer(
            id: id,
            idState: .parseable,
            attemptIDState: .unparseable
        )

        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session, clock: { now })
        await sender.requestDrain(trigger: .testDirect)
        await self.settleConnectivityCallback()
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertTrue(session.cancelledSegmentIDs.contains(id))
        XCTAssertEqual(session.transferredFiles.count, 1)
        let metadata = session.transferredFiles.first?.1
        XCTAssertNotNil(UUID(uuidString: metadata?["attempt_id"] as? String ?? ""))
    }

    func testRelayDeliveryCeilingTwinsAndConjunctions() async throws {
        let storage = try self.makeStorage("ceiling-twins")
        let storageActor = self.storageActor(for: storage)
        let session = MockWatchConnectivitySession()
        session.isReachable = true
        session.activate()

        // Twin 1: Age twin (started 3 days ago, but only attempt #1 today -> NOT abandoned)
        let idAge = UUID()
        let now = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storage, id: idAge, index: 0, state: .queued, startedAt: now.addingTimeInterval(-3 * 86400))
        var manifestAge = (await storageActor.scanCatalog(transactionClass: .captureSafety)).entries.first { $0.manifest.id == idAge }!.manifest
        manifestAge.relayDeliveryAttemptCount = 1
        manifestAge.relayDeliveryEffortSeconds = 300
        _ = try await storageActor.writeManifest(manifestAge, ensuringDirectory: false, transactionClass: .captureSafety)

        let sender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session, clock: { now })
        await sender.requestDrain(trigger: .testDirect)
        let stateAge = try await self.manifestState(storage: storage, id: idAge)
        XCTAssertNotEqual(stateAge, .abandoned)

        // Twin 2: Unreachability twin (many drain passes while unreachable -> NOT abandoned)
        let idUnreachable = UUID()
        _ = try await self.writeSegment(storage: storage, id: idUnreachable, index: 1, state: .queued)
        let unreachableSession = MockWatchConnectivitySession()
        unreachableSession.isReachable = false
        unreachableSession.activate()
        let unreachableSender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: unreachableSession, clock: { now })
        for _ in 0..<10 {
            await unreachableSender.requestDrain(trigger: .testDirect)
        }
        let stateUnreachable = try await self.manifestState(storage: storage, id: idUnreachable)
        XCTAssertNotEqual(stateUnreachable, .abandoned)

        // Redrives do not reset manifest attempt count
        let redriveManifest = (await storageActor.scanCatalog(transactionClass: .captureSafety)).entries.first { $0.manifest.id == idAge }!.manifest
        XCTAssertGreaterThanOrEqual(redriveManifest.relayDeliveryAttemptCount ?? 0, 1)

        // Delivered segments are NEVER abandoned even if attempts and effort are high
        let idDelivered = UUID()
        _ = try await self.writeSegment(storage: storage, id: idDelivered, index: 2, state: .delivered, deliveredAt: now)
        var manifestDelivered = (await storageActor.scanCatalog(transactionClass: .captureSafety)).entries.first { $0.manifest.id == idDelivered }!.manifest
        manifestDelivered.relayDeliveryAttemptCount = 10
        manifestDelivered.relayDeliveryEffortSeconds = 100_000
        _ = try await storageActor.writeManifest(manifestDelivered, ensuringDirectory: false, transactionClass: .captureSafety)

        await sender.requestDrain(trigger: .testDirect)
        let stateDelivered = try await self.manifestState(storage: storage, id: idDelivered)
        XCTAssertEqual(stateDelivered, .delivered)
    }

    func testLivenessCancelLeavesFailureCountAndLastStructuredFailureUnchanged() async throws {
        let storage = try self.makeStorage("liveness-cancel-accounting")
        let id = UUID()
        var now = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .queued)
        let storageActor = self.storageActor(for: storage)
        let session = MockWatchConnectivitySession()
        session.isReachable = true
        session.activate()
        let sink = WatchSignpostTestSink()
        let sender = WatchRelaySender(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            clock: { now },
            signposter: WatchSignposter(sink: sink)
        )

        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(session.transferredFiles.count, 1)

        // Advance 31m to trigger stall cancel
        now = now.addingTimeInterval(1860)
        await sender.requestDrain(trigger: .testDirect)
        await self.settleConnectivityCallback()

        // Signpost / drain accounting must show failureCount == 0
        let drainEnd = try XCTUnwrap(sink.events.last { $0.boundary == .relayDrain && $0.kind == .end })
        XCTAssertEqual(drainEnd.fields.failureCount ?? 0, 0)
        let manifest = try await self.manifest(storage: storage, id: id)
        XCTAssertNil(manifest?.failureReason)
    }

    func testCancelWithNoCompletionRemainsRedrivable() async throws {
        let storage = try self.makeStorage("cancel-no-completion")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .queued)
        let session = MockWatchConnectivitySession()
        session.driveCompletionOnCancel = false
        session.isReachable = true
        session.activate()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session, clock: { now })

        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(session.transferredFiles.count, 1)

        // Cancel with no completion: remains in outstandingFileTransfers as cancelled
        session.outstandingFileTransfers.first?.cancel()
        XCTAssertTrue(session.outstandingFileTransfers.first?.snapshot.progress.isCancelled ?? false)

        // Next drain should recognize activeGroup is empty (cancelled) and redrive
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(session.transferredFiles.count, 2)
    }

    func testStaleCancelCompletionAfterRedriveDoesNotRequeueOrBookFailure() async throws {
        let storage = try self.makeStorage("stale-cancel-completion")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .queued)
        let session = MockWatchConnectivitySession()
        session.driveCompletionOnCancel = false
        session.isReachable = true
        session.activate()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session, clock: { now })

        // Attempt 1
        await sender.requestDrain(trigger: .testDirect)
        let attempt1Metadata = session.transferredFiles[0].1
        let attempt1ID = try XCTUnwrap(UUID(uuidString: attempt1Metadata["attempt_id"] as? String ?? ""))

        // Cancel Attempt 1 without completion
        session.outstandingFileTransfers.first?.cancel()

        // Attempt 2 starts on next drain
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(session.transferredFiles.count, 2)

        // Now delayed completion for Attempt 1 arrives with failure
        session.finishTransfer(attemptID: attempt1ID, failure: Self.transferFailure("stale attempt 1 failed"))
        await self.settleConnectivityCallback()

        // Disk state must remain .transferring (Attempt 2), not requeued to .queued
        let state = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(state, .transferring)
        let manifest = try await self.manifest(storage: storage, id: id)
        XCTAssertNil(manifest?.failureReason)
    }

    func testCancelThenRedriveWithLeftoverRetainedDoesNotCancelRedriveAsRedundant() async throws {
        let storage = try self.makeStorage("leftover-retained-redundancy")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 5_000_000)
        _ = try await self.writeSegment(storage: storage, id: id, index: 0, state: .queued)
        let session = MockWatchConnectivitySession()
        session.driveCompletionOnCancel = false
        session.isReachable = true
        session.activate()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session, clock: { now })

        await sender.requestDrain(trigger: .testDirect)
        session.outstandingFileTransfers.first?.cancel()

        // Redrive creates transfer 2 while transfer 1 is retained as cancelled
        await sender.requestDrain(trigger: .testDirect)
        XCTAssertEqual(session.transferredFiles.count, 2)

        // The second transfer must not have been cancelled by cancelRedundant
        let transfer2 = session.outstandingFileTransfers.last
        XCTAssertFalse(transfer2?.snapshot.progress.isCancelled ?? true)
    }

    func testOldQueuedManifestLiteralDecodesAndRemainsDeliverable() async throws {
        let storage = try self.makeStorage("old-manifest-literal")
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let storageActor = self.storageActor(for: storage)
        let directory = try await storageActor.prepareSegmentDirectory(day: "2026-08-01", segment: "2026-08-01T12:00:00.000Z-60s")
        try Data("audio-0".utf8).write(to: storage.audioURL(directory: directory), options: .atomic)

        // Old JSON literal containing no new fields
        let oldJSON = """
        {
            "id": "\(id.uuidString)",
            "day": "2026-08-01",
            "segment": "2026-08-01T12:00:00.000Z-60s",
            "state": "queued",
            "started_at": "2026-08-01T12:00:00.000Z",
            "duration": 60,
            "sensors": ["audio"],
            "partial": false,
            "lost": false,
            "gap": false,
            "fix_count": 0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WatchSegmentManifest.self, from: oldJSON)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.state, .queued)
        XCTAssertNil(decoded.relayDeliveryAttemptCount)
        XCTAssertNil(decoded.relayDeliveryEffortSeconds)
        XCTAssertNil(decoded.relayLastProgress)
        XCTAssertNil(decoded.relayLastProgressAt)
        XCTAssertNil(decoded.abandonedAt)

        // Write to storage and verify it can be promoted and transferred
        _ = try await storageActor.writeManifest(decoded, ensuringDirectory: false, transactionClass: .captureSafety)

        let session = MockWatchConnectivitySession()
        session.isReachable = true
        session.activate()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        await sender.requestDrain(trigger: .testDirect)

        XCTAssertEqual(session.transferredFiles.count, 1)
        let state = try await self.manifestState(storage: storage, id: id)
        XCTAssertEqual(state, .transferring)
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

    func makeStorage(_ name: String) throws -> WatchCaptureTestStorage {
        try WatchCaptureTestStorage(rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true))
    }

    func makeStorage(_ name: String, fileWriter: any WatchFileWriting) throws -> WatchCaptureTestStorage {
        try WatchCaptureTestStorage(
            rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true),
            fileWriter: fileWriter
        )
    }

    func writeSegment(
        storage: WatchCaptureTestStorage,
        id: UUID,
        index: Int,
        state: WatchSegmentState = .queued,
        startedAt: Date? = nil,
        deliveredAt: Date? = nil
    ) async throws -> URL {
        let segmentStartedAt = startedAt ?? Date(timeIntervalSince1970: 1_713_624_000 + Double(index * 60))
        let day = storage.dayString(for: segmentStartedAt)
        let segment = storage.segmentString(for: segmentStartedAt, durationSeconds: 60)
        let storageActor = WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: storage.fileWriter
        )
        let directory = try await storageActor.prepareSegmentDirectory(day: day, segment: segment)
        let manifest = WatchSegmentManifest(
            id: id,
            day: day,
            segment: segment,
            startedAt: segmentStartedAt,
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
        try await storageActor.writeManifest(manifest, ensuringDirectory: false, transactionClass: .captureSafety)
        return directory
    }

    func deliverTransfer(
        from watchSession: MockWatchConnectivitySession,
        index: Int,
        to phoneSession: MockWatchConnectivitySession
    ) async throws {
        let transfer = watchSession.transferredFiles[index]
        let scratchDirectory = self.tempDirectory.appendingPathComponent("delivered-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let scratchURL = scratchDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("watchrelay")
        try FileManager.default.copyItem(at: transfer.0, to: scratchURL)
        phoneSession.deliverFile(scratchURL, metadata: transfer.1)
        await Task.yield()
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

    func manifest(storage: WatchCaptureTestStorage, id: UUID) async throws -> WatchSegmentManifest? {
        await self.catalogEntries(for: storage).first { $0.manifest.id == id }?.manifest
    }

    func manifestState(storage: WatchCaptureTestStorage, id: UUID) async throws -> WatchSegmentState {
        let manifest = try await self.manifest(storage: storage, id: id)
        return try XCTUnwrap(manifest).state
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

    func settleConnectivityCallback() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    func cancelOutstandingAndRedrive(
        sender: WatchRelaySender,
        session: MockWatchConnectivitySession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let priorCount = session.transferredFiles.count
        session.outstandingFileTransfers.first?.cancel()
        for _ in 0..<8 {
            await self.settleConnectivityCallback()
            await sender.requestDrain(trigger: .testDirect)
            if session.transferredFiles.count > priorCount {
                return
            }
        }
        XCTAssertGreaterThan(
            session.transferredFiles.count,
            priorCount,
            "expected a redrive on an empty-outstanding pass after cancel",
            file: file,
            line: line
        )
    }

    func drain(
        until condition: () async -> Bool,
        maxYields: Int = 10_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<maxYields {
            if await condition() { return }
            await Task.yield()
        }
        if await condition() { return }
        XCTFail(
            "drain(until:) exhausted \(maxYields) yields without the condition becoming true",
            file: file,
            line: line
        )
    }

    func waitForManifestState(
        storage: WatchCaptureTestStorage,
        id: UUID,
        expected: WatchSegmentState
    ) async {
        await self.drain(until: {
            let entries = await self.catalogEntries(for: storage)
            return entries.first { $0.manifest.id == id }?.manifest.state == expected
        })
    }

    func waitForNoManifests(in storage: WatchCaptureTestStorage) async {
        await self.drain(until: {
            await self.catalogEntries(for: storage).isEmpty
        })
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

@MainActor
private final class RelayTransferOrderProbe {
    var bundleWriteCompleted = false
    var transferObservedBundleWrite = false
}

private actor RelayBundleOrderingWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private let bundleURL: URL
    private let onBundleWrite: @MainActor @Sendable () -> Void

    init(
        bundleURL: URL,
        onBundleWrite: @escaping @MainActor @Sendable () -> Void
    ) {
        self.bundleURL = bundleURL
        self.onBundleWrite = onBundleWrite
    }

    func createDirectory(at url: URL) async throws { try await self.base.createDirectory(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }
    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        try await self.base.itemKind(at: url)
    }
    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }
    func readData(from url: URL) async throws -> Data { try await self.base.readData(from: url) }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        try await self.base.writeData(data, to: url, options: options)
        if url == self.bundleURL {
            await self.onBundleWrite()
        }
    }

    func appendLine(_ line: Data, to url: URL) async throws { try await self.base.appendLine(line, to: url) }
    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.base.atomicReplaceFile(at: url, with: data)
    }
    func removeItem(at url: URL) async throws { try await self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.base.moveItem(at: sourceURL, to: destinationURL)
    }
    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.base.contentsOfDirectory(at: url)
    }
}

private actor BlockingRelayCallbackWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var shouldBlockNextRead = false
    private var readEntered = false
    private var readEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var readReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var reads = 0

    func createDirectory(at url: URL) async throws { try await self.base.createDirectory(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }
    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        try await self.base.itemKind(at: url)
    }
    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }

    func readData(from url: URL) async throws -> Data {
        self.reads += 1
        if self.shouldBlockNextRead {
            self.shouldBlockNextRead = false
            self.readEntered = true
            let waiters = self.readEntryWaiters
            self.readEntryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                self.readReleaseWaiters.append(continuation)
            }
        }
        return try await self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        try await self.base.writeData(data, to: url, options: options)
    }
    func appendLine(_ line: Data, to url: URL) async throws { try await self.base.appendLine(line, to: url) }
    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.base.atomicReplaceFile(at: url, with: data)
    }
    func removeItem(at url: URL) async throws { try await self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.base.moveItem(at: sourceURL, to: destinationURL)
    }
    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.base.contentsOfDirectory(at: url)
    }

    func armNextRead() {
        self.shouldBlockNextRead = true
        self.readEntered = false
    }

    func waitUntilReadEntered() async {
        guard !self.readEntered else { return }
        await withCheckedContinuation { continuation in
            self.readEntryWaiters.append(continuation)
        }
    }

    func releaseRead() {
        let waiters = self.readReleaseWaiters
        self.readReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func readCount() -> Int { self.reads }
}
