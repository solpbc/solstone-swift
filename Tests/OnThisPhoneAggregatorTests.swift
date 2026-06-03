// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneAggregatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testAggregatorMergesSourcesNewestFirstWithCountsKindsAndPayloads() throws {
        let queues = self.makeQueues()
        let sessionID = UUID()
        let audioChunkID = "chunk-a"
        let audioID = "audio:\(sessionID.uuidString):\(audioChunkID)"
        let locationID = "location:20260603-110000_300"
        let shareID = "share-delivered"

        try self.writeObserverChunk(
            root: queues.observerRoot,
            sessionID: sessionID,
            chunkID: audioChunkID,
            status: "pending",
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 42
        )
        try self.writeLocationSegment(
            root: queues.locationRoot,
            status: "failed",
            fileID: "20260603-110000_300",
            fixCount: 7
        )
        try self.writeShareLedger(
            root: queues.importRoot,
            itemID: shareID,
            deliveredAt: Date(timeIntervalSince1970: 1_780_473_600)
        )

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            observerUploader: queues.observerUploader,
            locationUploader: queues.locationUploader
        )

        XCTAssertEqual(snapshot.items.map(\.id), [audioID, locationID, shareID])
        XCTAssertEqual(try self.count(for: .audio, in: snapshot), 1)
        XCTAssertEqual(try self.count(for: .location, in: snapshot), 1)
        XCTAssertEqual(try self.count(for: .share, in: snapshot), 1)
        XCTAssertEqual(snapshot.items.map(\.sourceKind), [.audio, .location, .share])
        XCTAssertEqual(snapshot.items.first { $0.id == audioID }?.sendState, .savedOnThisPhone)
        XCTAssertEqual(snapshot.items.first { $0.id == locationID }?.sendState, .needsAttention)
        XCTAssertEqual(snapshot.items.first { $0.id == shareID }?.sendState, .inYourJournal)
        XCTAssertEqual(snapshot.items.first { $0.id == audioID }?.audioDurationS, 42)
        XCTAssertEqual(snapshot.items.first { $0.id == locationID }?.locationFixCount, 7)

        let emptyQueues = self.makeQueues(suffix: "empty")
        let empty = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: emptyQueues.importQueue,
            observerUploader: emptyQueues.observerUploader,
            locationUploader: emptyQueues.locationUploader
        )
        XCTAssertEqual(empty.items, [])
        XCTAssertEqual(try self.count(for: .audio, in: empty), 0)
        XCTAssertEqual(try self.count(for: .location, in: empty), 0)
        XCTAssertEqual(try self.count(for: .share, in: empty), 0)
    }

    @MainActor
    func testAggregatorKeepsHealthySourcesWhenShareStoreFails() throws {
        let queues = self.makeQueues()
        let sessionID = UUID()
        let audioChunkID = "chunk-b"
        let audioID = "audio:\(sessionID.uuidString):\(audioChunkID)"
        let locationID = "location:20260603-110000_300"
        try self.writeObserverChunk(
            root: queues.observerRoot,
            sessionID: sessionID,
            chunkID: audioChunkID,
            status: "pending",
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 12
        )
        try self.writeLocationSegment(
            root: queues.locationRoot,
            status: "pending",
            fileID: "20260603-110000_300",
            fixCount: 3
        )
        try Data("{".utf8).write(to: queues.importRoot.appendingPathComponent("ledger.json"), options: .atomic)

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            observerUploader: queues.observerUploader,
            locationUploader: queues.locationUploader
        )

        XCTAssertEqual(snapshot.items.map(\.id), [audioID, locationID])
        XCTAssertTrue(try self.isFailed(.share, in: snapshot))
        XCTAssertEqual(try self.count(for: .audio, in: snapshot), 1)
        XCTAssertEqual(try self.count(for: .location, in: snapshot), 1)
    }
}

private extension OnThisPhoneAggregatorTests {
    struct Queues {
        let importRoot: URL
        let observerRoot: URL
        let locationRoot: URL
        let importQueue: ImportQueue
        let observerUploader: ObserverUploader
        let locationUploader: LocationUploader
    }

    @MainActor
    func makeQueues(suffix: String = "main") -> Queues {
        let importRoot = self.tempDirectory.appendingPathComponent("\(suffix)-import", isDirectory: true)
        let observerRoot = self.tempDirectory.appendingPathComponent("\(suffix)-observer", isDirectory: true)
        let locationRoot = self.tempDirectory.appendingPathComponent("\(suffix)-location", isDirectory: true)
        return Queues(
            importRoot: importRoot,
            observerRoot: observerRoot,
            locationRoot: locationRoot,
            importQueue: ImportQueue(
                cacheRootURL: importRoot,
                sessionConfiguration: .ephemeral,
                startPathMonitor: false
            ),
            observerUploader: ObserverUploader(
                cacheRootURL: observerRoot,
                sessionConfiguration: .ephemeral,
                startPathMonitor: false
            ),
            locationUploader: LocationUploader(
                cacheRootURL: locationRoot,
                sessionConfiguration: .ephemeral,
                startPathMonitor: false,
                timeZone: TimeZone(secondsFromGMT: 7_200)!
            )
        )
    }

    @MainActor
    func writeObserverChunk(
        root: URL,
        sessionID: UUID,
        chunkID: String,
        status: String,
        startedAt: Date,
        durationS: TimeInterval
    ) throws {
        let directory = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(status, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("\(chunkID).m4a"))
        let sidecar = ChunkSidecar(
            segment: "120000_300",
            day: "20260603",
            chunkIndex: 0,
            startedAt: startedAt,
            durationS: durationS,
            sessionID: sessionID,
            mode: .meeting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sidecar).write(to: directory.appendingPathComponent("\(chunkID).json"))
    }

    func writeLocationSegment(root: URL, status: String, fileID: String, fixCount: Int) throws {
        let directory = root.appendingPathComponent(status, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(
            #"{"accuracy":"full","fix_count":\#(fixCount),"gap":false,"kind":"location","platform":"ios","schema":"solstone.location.segment/1","source":"location","tier":"balanced"}"#
                .utf8
        ) + Data([0x0A])
        try data.write(to: directory.appendingPathComponent("\(fileID).jsonl"))
    }

    func writeShareLedger(root: URL, itemID: String, deliveredAt: Date) throws {
        let ledger = [
            itemID: ShareLedgerFixture(
                itemID: itemID,
                stream: "import.share",
                basis: "sent",
                contentType: "application/pdf",
                targetJournal: "home",
                serverDay: "20260603",
                serverSegment: "100000_0",
                deliveredAt: deliveredAt,
                filename: "share.pdf",
                originApp: nil,
                itemTime: nil
            ),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: root.appendingPathComponent("ledger.json"), options: .atomic)
    }

    func count(for sourceKind: OnThisPhoneSourceKind, in snapshot: OnThisPhoneAggregateSnapshot) throws -> Int {
        let result = try self.result(for: sourceKind, in: snapshot)
        guard case .loaded(let items) = result else {
            XCTFail("Expected loaded source")
            return 0
        }
        return items.count
    }

    func isFailed(_ sourceKind: OnThisPhoneSourceKind, in snapshot: OnThisPhoneAggregateSnapshot) throws -> Bool {
        let result = try self.result(for: sourceKind, in: snapshot)
        guard case .failed = result else { return false }
        return true
    }

    func result(for sourceKind: OnThisPhoneSourceKind, in snapshot: OnThisPhoneAggregateSnapshot) throws -> OnThisPhoneSourceResult {
        try XCTUnwrap(snapshot.sources.first { $0.sourceKind == sourceKind }?.result)
    }
}

private struct ShareLedgerFixture: Codable {
    let itemID: String
    let stream: String
    let basis: String
    let contentType: String
    let targetJournal: String
    let serverDay: String
    let serverSegment: String?
    let deliveredAt: Date
    let filename: String?
    let originApp: String?
    let itemTime: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case stream
        case basis
        case contentType = "content_type"
        case targetJournal = "target_journal"
        case serverDay = "server_day"
        case serverSegment = "server_segment"
        case deliveredAt = "delivered_at"
        case filename
        case originApp = "origin_app"
        case itemTime = "item_time"
    }
}
