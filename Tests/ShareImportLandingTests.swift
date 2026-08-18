// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ShareImportLandingTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportLandingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    // Criterion 1
    @MainActor
    func testSparseLargeFileLandsCompletePendingItem() async throws {
        let source = try self.makeSparseFile(named: "large.pdf", size: Self.largeByteCount)
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot)
        let coordinator = ShareImportCoordinator(queue: store)
        let provider = StubLandingProvider(contentType: "com.adobe.pdf", filename: "large.pdf", fileURL: source)

        let result = await coordinator.accept(provider: provider)

        guard case .success(let itemID) = result else {
            XCTFail("expected success")
            return
        }
        let itemIDString = itemID.uuidString.lowercased()
        let rawURL = queueRoot.appendingPathComponent("pending/\(itemIDString)/raw.bin")
        let noteURL = queueRoot.appendingPathComponent("pending/\(itemIDString)/item.json")
        let requestURL = queueRoot.appendingPathComponent("pending/\(itemIDString)/request.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        XCTAssertEqual(try self.fileSize(rawURL), Self.largeByteCount)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: queueRoot.appendingPathComponent("staging").path), [])
    }

    // Criterion 2 — same large fixture, three failure cases
    @MainActor
    func testLargeFixtureLoadFailureLeavesNoQueueEntry() async throws {
        let source = try self.makeSparseFile(named: "large.pdf", size: Self.largeByteCount)
        try await self.assertLargeFixtureLeavesNothing(
            provider: StubLandingProvider(
                contentType: "com.adobe.pdf",
                filename: "large.pdf",
                fileURL: source,
                loadError: StubLandingError.loadFailed
            ),
            expectedFailure: .unreadable
        )
    }

    @MainActor
    func testLargeFixtureUnsupportedTypeLeavesNoQueueEntry() async throws {
        let source = try self.makeSparseFile(named: "large.bin", size: Self.largeByteCount)
        try await self.assertLargeFixtureLeavesNothing(
            provider: StubLandingProvider(contentType: "public.url", filename: "large.bin", fileURL: source),
            expectedFailure: .unsupported
        )
    }

    @MainActor
    func testLargeFixtureProtectedFileLeavesNoQueueEntry() async throws {
        let source = self.tempDirectory.appendingPathComponent("large-protected.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try await self.assertLargeFixtureLeavesNothing(
            provider: StubLandingProvider(contentType: "com.adobe.pdf", filename: "large.pdf", fileURL: source),
            expectedFailure: .protected
        )
    }

    // Criterion 3
    @MainActor
    func testMissingCapacityAttributeFailsNoRoomAndLeavesNothingPending() async throws {
        let source = try self.makeSparseFile(named: "share.pdf", size: 4_096)
        let io = RecordingCapacityPayloadIO(capacity: nil)
        try await self.assertLandingFailure(source: source, payloadIO: io, expected: .noRoom)
        XCTAssertEqual(io.requestedCapacities.count, 1)
    }

    @MainActor
    func testReservationUsesOneTimesSizeWhenInPlaceAndTwoTimesWhenNot() async throws {
        let sourceSize: Int64 = 8_192
        let source = try self.makeSparseFile(named: "share.pdf", size: sourceSize)

        let inPlaceIO = RecordingCapacityPayloadIO(capacity: sourceSize)
        _ = try await self.land(source: source, payloadIO: inPlaceIO, isInPlace: true)
        XCTAssertFalse(inPlaceIO.requestedCapacities.isEmpty)

        let copiedIO = RecordingCapacityPayloadIO(capacity: sourceSize * 2)
        _ = try await self.land(source: source, payloadIO: copiedIO, isInPlace: false)
        XCTAssertFalse(copiedIO.requestedCapacities.isEmpty)

        let shortfallIO = RecordingCapacityPayloadIO(capacity: sourceSize * 2 - 1)
        try await self.assertLandingFailure(source: source, payloadIO: shortfallIO, isInPlace: false, expected: .noRoom)
        let inPlaceShortfall = RecordingCapacityPayloadIO(capacity: sourceSize - 1)
        try await self.assertLandingFailure(source: source, payloadIO: inPlaceShortfall, isInPlace: true, expected: .noRoom)
    }

    // Criterion 4
    @MainActor
    func testMidCopyENOSPCMapsToNoRoom() async throws {
        let source = try self.makeSparseFile(named: "share.pdf", size: 4_096)
        let io = CopyFailingPayloadIO(error: CocoaError(.fileWriteOutOfSpace))
        try await self.assertLandingFailure(source: source, payloadIO: io, expected: .noRoom)

        let posixIO = CopyFailingPayloadIO(error: POSIXError(.ENOSPC))
        try await self.assertLandingFailure(source: source, payloadIO: posixIO, expected: .noRoom)
    }

    // Criterion 5
    @MainActor
    func testPayloadReadThrowStillProducesCompletePendingItem() async throws {
        let payload = Data("payload-bytes".utf8)
        let source = try self.makeFile(named: "share.pdf", data: payload)
        let io = ThrowingPayloadReadShareImportPayloadIO(payloadURL: source)
        let landed = try await self.land(source: source, payloadIO: io, isInPlace: true)
        let rawURL = landed.queueRoot
            .appendingPathComponent("pending/\(landed.itemID.uuidString.lowercased())/raw.bin")
        XCTAssertEqual(try Data(contentsOf: rawURL), payload)
        XCTAssertFalse(io.didReadPayload)
        let store = ShareImportStore(cacheRootURL: landed.queueRoot, payloadIO: io)
        _ = store.onThisPhoneSourceSnapshot()
        XCTAssertTrue(io.didReadJSON)
    }

    // Criterion 8
    @MainActor
    func testAbortedLandingLeavesPendingEmpty() async throws {
        let source = try self.makeFile(named: "share.pdf", data: Data("pdf".utf8))
        let io = CopyFailingPayloadIO(error: CocoaError(.fileWriteUnknown))
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot, payloadIO: io)
        let coordinator = ShareImportCoordinator(queue: store)
        let result = await coordinator.accept(
            provider: StubLandingProvider(contentType: "com.adobe.pdf", filename: "share.pdf", fileURL: source)
        )
        XCTAssertEqual(result, .failure(.unreadable))
        try self.assertQueueDirectoriesEmpty(root: queueRoot)
    }

    @MainActor
    private func assertLargeFixtureLeavesNothing(
        provider: StubLandingProvider,
        expectedFailure: ShareImportFailure
    ) async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot)
        let coordinator = ShareImportCoordinator(queue: store)
        let result = await coordinator.accept(provider: provider)
        XCTAssertEqual(result, .failure(expectedFailure))
        try self.assertQueueDirectoriesEmpty(root: queueRoot)
    }

    @MainActor
    private func assertLandingFailure(
        source: URL,
        payloadIO: any ShareImportPayloadIO,
        isInPlace: Bool = true,
        expected: ShareImportFailure
    ) async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot, payloadIO: payloadIO)
        let coordinator = ShareImportCoordinator(queue: store)
        let result = await coordinator.accept(
            provider: StubLandingProvider(
                contentType: "com.adobe.pdf",
                filename: "share.pdf",
                fileURL: source,
                isInPlace: isInPlace
            )
        )
        XCTAssertEqual(result, .failure(expected))
        try self.assertQueueDirectoriesEmpty(root: queueRoot)
    }

    @MainActor
    @discardableResult
    private func land(
        source: URL,
        payloadIO: any ShareImportPayloadIO,
        isInPlace: Bool
    ) async throws -> (itemID: UUID, queueRoot: URL) {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot, payloadIO: payloadIO)
        let coordinator = ShareImportCoordinator(queue: store)
        let result = await coordinator.accept(
            provider: StubLandingProvider(
                contentType: "com.adobe.pdf",
                filename: "share.pdf",
                fileURL: source,
                isInPlace: isInPlace
            )
        )
        guard case .success(let itemID) = result else {
            XCTFail("expected success")
            throw StubLandingError.loadFailed
        }
        return (itemID, queueRoot)
    }

    private func assertQueueDirectoriesEmpty(root: URL) throws {
        for subdirectory in ["pending", "failed", "staging"] {
            let directory = root.appendingPathComponent(subdirectory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertTrue(entries.isEmpty, "\(subdirectory) should be empty")
        }
    }

    private func makeFile(named name: String, data: Data) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeSparseFile(named name: String, size: Int64) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(try XCTUnwrap(values.fileSize))
    }

    private static let largeByteCount: Int64 = 150 * 1024 * 1024
}

@MainActor
private final class StubLandingProvider: ShareItemProvider {
    let contentType: String?
    let filename: String?
    let fileURL: URL?
    let loadError: Error?
    let isInPlace: Bool

    init(
        contentType: String?,
        filename: String?,
        fileURL: URL?,
        loadError: Error? = nil,
        isInPlace: Bool = true
    ) {
        self.contentType = contentType
        self.filename = filename
        self.fileURL = fileURL
        self.loadError = loadError
        self.isInPlace = isInPlace
    }

    func registeredContentType() -> String? { self.contentType }
    func suggestedFilename() -> String? { self.filename }

    func deliverFile(to sink: any ShareFileSink) async throws -> ShareFileDelivery {
        if let loadError { throw loadError }
        guard let fileURL else { throw StubLandingError.loadFailed }
        return try sink.consume(sourceURL: fileURL, isInPlace: self.isInPlace)
    }

    func loadText() async throws -> String {
        throw StubLandingError.loadFailed
    }
}

private enum StubLandingError: Error {
    case loadFailed
}

private final class RecordingCapacityPayloadIO: ShareImportPayloadIO, @unchecked Sendable {
    private let base = FoundationShareImportPayloadIO()
    private let capacity: Int64?
    private let lock = NSLock()
    private var requested: [URL] = []

    init(capacity: Int64?) {
        self.capacity = capacity
    }

    var requestedCapacities: [URL] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requested
    }

    func byteCount(at url: URL) throws -> Int64 { try self.base.byteCount(at: url) }
    func itemDates(at url: URL) throws -> (created: Date?, modified: Date?) { try self.base.itemDates(at: url) }
    func importantUsageCapacity(at url: URL) throws -> Int64? {
        self.lock.lock()
        self.requested.append(url)
        self.lock.unlock()
        return self.capacity
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.copyItem(at: sourceURL, to: destinationURL)
    }
    func readWholeFile(at url: URL) throws -> Data { try self.base.readWholeFile(at: url) }
}

private final class CopyFailingPayloadIO: ShareImportPayloadIO, @unchecked Sendable {
    private let base = FoundationShareImportPayloadIO()
    private let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func byteCount(at url: URL) throws -> Int64 { try self.base.byteCount(at: url) }
    func itemDates(at url: URL) throws -> (created: Date?, modified: Date?) { try self.base.itemDates(at: url) }
    func importantUsageCapacity(at url: URL) throws -> Int64? { try self.base.importantUsageCapacity(at: url) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { throw self.error }
    func readWholeFile(at url: URL) throws -> Data { try self.base.readWholeFile(at: url) }
}

private final class ThrowingPayloadReadShareImportPayloadIO: ShareImportPayloadIO, @unchecked Sendable {
    private let base = FoundationShareImportPayloadIO()
    private let payloadURL: URL
    private let lock = NSLock()
    private var readPayload = false
    private var readJSON = false

    init(payloadURL: URL) {
        self.payloadURL = payloadURL.standardizedFileURL
    }

    var didReadPayload: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.readPayload
    }

    var didReadJSON: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.readJSON
    }

    func byteCount(at url: URL) throws -> Int64 { try self.base.byteCount(at: url) }
    func itemDates(at url: URL) throws -> (created: Date?, modified: Date?) { try self.base.itemDates(at: url) }
    func importantUsageCapacity(at url: URL) throws -> Int64? { try self.base.importantUsageCapacity(at: url) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.copyItem(at: sourceURL, to: destinationURL)
    }
    func readWholeFile(at url: URL) throws -> Data {
        if url.standardizedFileURL == self.payloadURL {
            self.lock.lock()
            self.readPayload = true
            self.lock.unlock()
            throw CocoaError(.fileReadUnknown)
        }
        self.lock.lock()
        self.readJSON = true
        self.lock.unlock()
        return try self.base.readWholeFile(at: url)
    }
}
