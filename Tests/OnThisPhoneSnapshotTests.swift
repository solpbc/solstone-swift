// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneSnapshotTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        super.tearDown()
    }

    @MainActor
    func testSnapshotReadsPendingFailedAndDeliveredValuesNewestFirst() throws {
        let queue = self.makeQueue()
        let pendingID = UUID().uuidString.lowercased()
        let failedID = UUID().uuidString.lowercased()
        let deliveredID = UUID().uuidString.lowercased()
        let pendingTime = Date(timeIntervalSince1970: 1_713_624_100)
        let failedTime = Date(timeIntervalSince1970: 1_713_624_200)
        let deliveredAt = Date(timeIntervalSince1970: 1_713_624_300)

        try self.writeLocalItem(
            itemID: pendingID,
            status: "pending",
            rawData: Data("pending".utf8),
            note: try self.note(
                itemID: pendingID,
                filename: "pending.pdf",
                contentType: "com.adobe.pdf",
                bytes: 7,
                originApp: "com.example.pending",
                basis: "modified",
                itemTime: Self.iso8601String(for: pendingTime),
                targetJournal: "daily"
            ),
            request: try self.request(day: "20260420", segment: "120010_0", stream: "import.share")
        )
        try self.writeLocalItem(
            itemID: failedID,
            status: "failed",
            rawData: Data("failed".utf8),
            note: try self.note(
                itemID: failedID,
                filename: "failed.jpg",
                contentType: "public.jpeg",
                bytes: 6,
                originApp: "com.example.failed",
                basis: "created",
                itemTime: Self.iso8601String(for: failedTime),
                targetJournal: "photos"
            ),
            request: try self.request(day: "20260421", segment: "120020_0", stream: "import.share")
        )
        try self.writeLedger([
            deliveredID: LedgerFixture(
                itemID: deliveredID,
                stream: "import.share",
                basis: "sent",
                contentType: "public.png",
                targetJournal: "archive",
                serverDay: "20260422",
                serverSegment: "120030_0",
                deliveredAt: deliveredAt,
                filename: "delivered.png",
                originApp: "com.example.delivered",
                itemTime: Self.iso8601String(for: Date(timeIntervalSince1970: 1_713_624_000))
            ),
        ])

        let items = try self.loadedItems(from: queue.onThisPhoneSourceSnapshot())

        XCTAssertEqual(items.map(\.id), [deliveredID, failedID, pendingID])
        let pending = try XCTUnwrap(items.first { $0.id == pendingID })
        XCTAssertEqual(pending.sendState, .savedOnThisPhone)
        XCTAssertEqual(pending.filename, "pending.pdf")
        XCTAssertEqual(pending.contentType, "com.adobe.pdf")
        XCTAssertEqual(pending.bytes, 7)
        XCTAssertEqual(pending.originApp, "com.example.pending")
        XCTAssertEqual(pending.basis, "modified")
        XCTAssertEqual(pending.targetJournal, "daily")
        XCTAssertEqual(pending.stream, "import.share")
        XCTAssertEqual(pending.day, "20260420")
        XCTAssertEqual(pending.segment, "120010_0")
        XCTAssertEqual(pending.hasLocalRaw, true)

        let failed = try XCTUnwrap(items.first { $0.id == failedID })
        XCTAssertEqual(failed.sendState, .needsAttention)

        let delivered = try XCTUnwrap(items.first { $0.id == deliveredID })
        XCTAssertEqual(delivered.sendState, .inYourJournal)
        XCTAssertEqual(delivered.contentType, "public.png")
        XCTAssertEqual(delivered.filename, "delivered.png")
        XCTAssertEqual(delivered.originApp, "com.example.delivered")
        XCTAssertEqual(delivered.basis, "sent")
        XCTAssertEqual(delivered.targetJournal, "archive")
        XCTAssertEqual(delivered.stream, "import.share")
        XCTAssertEqual(delivered.day, "20260422")
        XCTAssertEqual(delivered.segment, "120030_0")
        XCTAssertEqual(delivered.deliveredAt, deliveredAt)
        XCTAssertEqual(delivered.hasLocalRaw, false)
    }

    @MainActor
    func testIncompletePendingItemAppearsWithNilMetadataAndRawURL() throws {
        let queue = self.makeQueue()
        let itemID = UUID().uuidString.lowercased()
        try self.writeLocalItem(
            itemID: itemID,
            status: "pending",
            rawData: Data("raw".utf8),
            note: Data("{}".utf8),
            request: try self.request(day: "20260420", segment: "120000_0", stream: "import.share")
        )

        let item = try XCTUnwrap(self.loadedItems(from: queue.onThisPhoneSourceSnapshot()).first)

        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.sendState, .savedOnThisPhone)
        XCTAssertNil(item.filename)
        XCTAssertNil(item.contentType)
        XCTAssertNil(item.bytes)
        XCTAssertNil(item.originApp)
        XCTAssertNil(item.basis)
        XCTAssertNil(item.targetJournal)
        XCTAssertEqual(item.stream, "import.share")
        XCTAssertEqual(item.hasLocalRaw, true)
    }

    @MainActor
    func testEmptyAndCorruptLedgerResults() throws {
        let queue = self.makeQueue()
        XCTAssertEqual(queue.onThisPhoneSourceSnapshot(), .loaded(items: []))

        try Data("{".utf8).write(to: self.ledgerURL(), options: .atomic)
        XCTAssertEqual(queue.onThisPhoneSourceSnapshot(), .failed)
    }

    @MainActor
    func testSnapshotDoesNotMutateQueueOrLedger() throws {
        let queue = self.makeQueue()
        let pendingID = UUID().uuidString.lowercased()
        let failedID = UUID().uuidString.lowercased()
        let deliveredID = UUID().uuidString.lowercased()
        try self.writeLocalItem(
            itemID: pendingID,
            status: "pending",
            rawData: Data("pending".utf8),
            note: try self.note(
                itemID: pendingID,
                filename: "pending.pdf",
                contentType: "com.adobe.pdf",
                bytes: 7,
                originApp: nil,
                basis: "sent",
                itemTime: Self.iso8601String(for: Date(timeIntervalSince1970: 1)),
                targetJournal: "daily"
            ),
            request: try self.request(day: "20260420", segment: "120000_0", stream: "import.share")
        )
        try self.writeLocalItem(
            itemID: failedID,
            status: "failed",
            rawData: Data("failed".utf8),
            note: Data("{}".utf8),
            request: try self.request(day: "20260420", segment: "120001_0", stream: "import.share")
        )
        try self.writeLedger([
            deliveredID: LedgerFixture(
                itemID: deliveredID,
                stream: "import.share",
                basis: "sent",
                contentType: "public.png",
                targetJournal: "archive",
                serverDay: "20260422",
                serverSegment: "120030_0",
                deliveredAt: Date(timeIntervalSince1970: 2),
                filename: "delivered.png",
                originApp: nil,
                itemTime: nil
            ),
        ])
        let pendingCount = queue.pendingCount
        let failedCount = queue.failedCount
        let pendingBefore = try self.directoryEntries(status: "pending")
        let failedBefore = try self.directoryEntries(status: "failed")
        let ledgerBefore = try Data(contentsOf: self.ledgerURL())

        _ = queue.onThisPhoneSourceSnapshot()

        XCTAssertEqual(queue.pendingCount, pendingCount)
        XCTAssertEqual(queue.failedCount, failedCount)
        XCTAssertEqual(try self.directoryEntries(status: "pending"), pendingBefore)
        XCTAssertEqual(try self.directoryEntries(status: "failed"), failedBefore)
        XCTAssertEqual(try Data(contentsOf: self.ledgerURL()), ledgerBefore)
    }

    @MainActor
    func testRawAvailabilityDiffersForLocalAndDeliveredItems() throws {
        let queue = self.makeQueue()
        let pendingID = UUID().uuidString.lowercased()
        let deliveredID = UUID().uuidString.lowercased()
        try self.writeLocalItem(
            itemID: pendingID,
            status: "pending",
            rawData: Data("pending".utf8),
            note: Data("{}".utf8),
            request: try self.request(day: "20260420", segment: "120000_0", stream: "import.share")
        )
        try self.writeLedger([
            deliveredID: LedgerFixture(
                itemID: deliveredID,
                stream: "import.share",
                basis: "sent",
                contentType: "public.png",
                targetJournal: "archive",
                serverDay: "20260422",
                serverSegment: nil,
                deliveredAt: Date(timeIntervalSince1970: 2),
                filename: "delivered.png",
                originApp: nil,
                itemTime: nil
            ),
        ])

        let items = try self.loadedItems(from: queue.onThisPhoneSourceSnapshot())

        XCTAssertNotNil(items.first { $0.id == pendingID }?.rawFileURL)
        XCTAssertEqual(items.first { $0.id == pendingID }?.hasLocalRaw, true)
        XCTAssertNil(items.first { $0.id == deliveredID }?.rawFileURL)
        XCTAssertEqual(items.first { $0.id == deliveredID }?.hasLocalRaw, false)
        XCTAssertEqual(items.first { $0.id == deliveredID }?.filename, "delivered.png")
    }

    @MainActor
    private func makeQueue() -> ImportQueue {
        let configuration = URLSessionConfiguration.ephemeral
        return ImportQueue(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: configuration,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false,
            now: { Date(timeIntervalSince1970: 1_713_624_000) }
        )
    }

    private func writeLocalItem(itemID: String, status: String, rawData: Data?, note: Data, request: Data) throws {
        let directory = self.itemDirectory(itemID: itemID, status: status)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let rawData {
            try rawData.write(to: directory.appendingPathComponent("raw.bin"))
        }
        try note.write(to: directory.appendingPathComponent("item.json"))
        try request.write(to: directory.appendingPathComponent("request.json"))
    }

    private func note(
        itemID: String,
        filename: String?,
        contentType: String,
        bytes: Int64,
        originApp: String?,
        basis: String,
        itemTime: String,
        targetJournal: String
    ) throws -> Data {
        let object: [String: Any?] = [
            "schema": "solstone.source.item/1",
            "source": "share",
            "origin_app": originApp,
            "content_type": contentType,
            "filename": filename,
            "bytes": bytes,
            "basis": basis,
            "item_time": itemTime,
            "target_journal": targetJournal,
            "kind": "raw",
            "item_id": itemID,
        ]
        return try JSONSerialization.data(withJSONObject: object.mapValues { $0 ?? NSNull() }, options: [.sortedKeys])
    }

    private func request(day: String, segment: String, stream: String) throws -> Data {
        let object = [
            "day": day,
            "segment": segment,
            "stream": stream,
            "filename": "document.pdf",
            "content_type": "application/pdf",
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func writeLedger(_ ledger: [String: LedgerFixture]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: self.ledgerURL(), options: .atomic)
    }

    private func loadedItems(from result: OnThisPhoneSourceResult) throws -> [OnThisPhoneItem] {
        guard case .loaded(let items) = result else {
            XCTFail("Expected loaded result")
            return []
        }
        return items
    }

    private func directoryEntries(status: String) throws -> [String] {
        let directory = self.tempDirectory.appendingPathComponent(status, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func itemDirectory(itemID: String, status: String) -> URL {
        self.tempDirectory
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
    }

    private func ledgerURL() -> URL {
        self.tempDirectory.appendingPathComponent("ledger.json")
    }

    private static func iso8601String(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct LedgerFixture: Codable {
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
