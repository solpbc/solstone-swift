// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
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

        sender.drain()

        XCTAssertEqual(watchSession.transferredFiles.count, 1)
        XCTAssertTrue(storage.fileWriter.fileExists(at: directory))
        let firstManifest = try XCTUnwrap(try storage.scanManifests().first?.manifest)
        XCTAssertEqual(firstManifest.id, id)
        XCTAssertEqual(firstManifest.state, .transferring)

        let relaunchedSession = MockWatchConnectivitySession()
        let relaunchedSender = WatchRelaySender(storage: storage, session: relaunchedSession)
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
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(try self.stagedEntryIDs(at: stagingRoot), [id.uuidString])
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)

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
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

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
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertTrue(phoneSession.sentMessages.isEmpty)
        XCTAssertEqual(phoneSession.transferredUserInfos.count, 1)
        self.assertRelayACK(phoneSession.transferredUserInfos[0], id: id)

        watchSession.deliverUserInfo(phoneSession.transferredUserInfos[0])

        XCTAssertFalse(storage.fileWriter.fileExists(at: sourceDirectory))
        XCTAssertEqual(try storage.scanManifests().count, 0)
    }

    func testFastAndDurableACKDeliveryIsIdempotent() throws {
        let storage = try self.makeStorage("idempotent-ack-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("idempotent-ack-staging", isDirectory: true)
        let id = UUID()
        let sourceDirectory = try self.writeSegment(storage: storage, id: id, index: 0)
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

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
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        var stagedIDs: [UUID] = []
        receiver.onSegmentStaged = { stagedIDs.append($0) }
        defer { withExtendedLifetime(receiver) {} }

        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(stagedIDs, [id])

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
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        let invalidScratch = self.tempDirectory.appendingPathComponent("invalid-watchrelay")
        try Data("not a segment bundle".utf8).write(to: invalidScratch, options: .atomic)
        receiver.receiveFile(invalidScratch, metadata: ["id": UUID().uuidString])
        XCTAssertNotNil(receiver.lastStagingError)
        defer { withExtendedLifetime(receiver) {} }

        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)

        XCTAssertEqual(receiver.receivedCount, 1)
        XCTAssertNotNil(receiver.lastReceivedAt)
        XCTAssertNil(receiver.lastStagingError)

        let waiting = WatchSourceDetailPresentation.syncSummary(
            received: receiver.receivedCount,
            pending: 1,
            failed: 0,
            lastUploadAt: nil
        )
        XCTAssertEqual(waiting.received, 1)
        XCTAssertEqual(waiting.waiting, 1)
        XCTAssertEqual(waiting.handedToJournal, 0)

        let handed = WatchSourceDetailPresentation.syncSummary(
            received: receiver.receivedCount,
            pending: 0,
            failed: 0,
            lastUploadAt: Date(timeIntervalSince1970: 1_000)
        )
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
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 0, to: phoneSession)
        let firstReceivedAt = try XCTUnwrap(receiver.lastReceivedAt)
        Thread.sleep(forTimeInterval: 0.01)

        sender.drain()
        try self.deliverTransfer(from: watchSession, index: 1, to: phoneSession)

        XCTAssertEqual(receiver.receivedCount, 1)
        let duplicateReceivedAt = try XCTUnwrap(receiver.lastReceivedAt)
        XCTAssertGreaterThan(duplicateReceivedAt.timeIntervalSinceReferenceDate, firstReceivedAt.timeIntervalSinceReferenceDate)
    }

    func testReceiverInstrumentationTracksStagingFailure() throws {
        let stagingRoot = self.tempDirectory.appendingPathComponent("instrumentation-failure-staging", isDirectory: true)
        let phoneSession = MockWatchConnectivitySession()
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        let scratchURL = self.tempDirectory.appendingPathComponent("invalid-watchrelay")
        try Data("not a segment bundle".utf8).write(to: scratchURL, options: .atomic)
        defer { withExtendedLifetime(receiver) {} }

        receiver.receiveFile(scratchURL, metadata: ["id": UUID().uuidString])

        XCTAssertEqual(receiver.receivedCount, 0)
        XCTAssertNil(receiver.lastReceivedAt)
        XCTAssertNotNil(receiver.lastStagingError)
    }

    func testBacklogDrainsOneDistinctSegmentAtATime() throws {
        let storage = try self.makeStorage("backlog-watch")
        let stagingRoot = self.tempDirectory.appendingPathComponent("backlog-staging", isDirectory: true)
        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            _ = try self.writeSegment(storage: storage, id: id, index: index)
        }
        let watchSession = MockWatchConnectivitySession()
        let phoneSession = MockWatchConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: watchSession)
        let receiver = try WatchRelayReceiver(session: phoneSession, stagingRootURL: stagingRoot)
        defer { withExtendedLifetime(receiver) {} }

        watchSession.emitReachability(false)
        XCTAssertTrue(watchSession.transferredFiles.isEmpty)

        watchSession.emitReachability(true)
        sender.drain()

        var deliveredFiles = 0
        var deliveredACKs = 0
        while deliveredACKs < ids.count {
            XCTAssertLessThanOrEqual(try self.transferringCount(in: storage), WatchRelaySender.maxInFlight)
            guard watchSession.transferredFiles.count > deliveredFiles else {
                return XCTFail("expected queued relay bundle \(deliveredFiles + 1)")
            }
            try self.deliverTransfer(from: watchSession, index: deliveredFiles, to: phoneSession)
            deliveredFiles += 1

            guard phoneSession.transferredUserInfos.count > deliveredACKs else {
                return XCTFail("expected relay ACK \(deliveredACKs + 1)")
            }
            watchSession.deliverUserInfo(phoneSession.transferredUserInfos[deliveredACKs])
            deliveredACKs += 1
        }

        XCTAssertEqual(Set(try self.stagedEntryIDs(at: stagingRoot)), Set(ids.map(\.uuidString)))
        XCTAssertEqual(try storage.scanManifests().count, 0)
        XCTAssertEqual(deliveredFiles, ids.count)
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

        let handedOff = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, handedOffCount: 1)
        XCTAssertEqual(handedOff.headline, "handed to your iphone")
        XCTAssertEqual(handedOff.countsLine, "1 handed to your iphone")
        XCTAssertNil(handedOff.attentionLine)

        let attention = WatchCaptureOwnerPresentation(
            status: .needsAttention(.diskFull),
            queuedCount: 1,
            transferringCount: 1,
            handedOffCount: 1
        )
        XCTAssertEqual(attention.headline, "storage is full")
        XCTAssertEqual(attention.countsLine, "1 sending · 1 saved on your watch · 1 handed to your iphone")
        XCTAssertEqual(attention.attentionLine, "storage is full")
    }
}

@MainActor
private extension WatchRelayTests {
    func makeStorage(_ name: String) throws -> WatchCaptureStorage {
        try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true))
    }

    func writeSegment(storage: WatchCaptureStorage, id: UUID, index: Int) throws -> URL {
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
            state: .queued,
            failureReason: nil
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

    func transferringCount(in storage: WatchCaptureStorage) throws -> Int {
        try storage.scanManifests().filter { $0.manifest.state == .transferring }.count
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
}
