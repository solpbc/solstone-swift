// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ImportQueueTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportQueueTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        ImportQueueURLProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        ImportQueueURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testAppGroupContainerIdentifierAndImportQueueSubpath() {
        XCTAssertEqual(AppGroupContainer.identifier, "group.app.solstone.swift")

        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.tempDirectory.appendingPathComponent("pending").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.tempDirectory.appendingPathComponent("failed").path))
    }

    func testBackgroundConfigurationUsesSharedContainer() {
        let config = ImportQueue.makeBackgroundConfiguration()
        XCTAssertEqual(config.identifier, ImportQueue.backgroundSessionIdentifier)
        XCTAssertEqual(config.sharedContainerIdentifier, AppGroupContainer.identifier)
        XCTAssertTrue(config.waitsForConnectivity)
    }

    @MainActor
    func testEnqueueWritesPendingArtifactsWithImporterDescriptor() async throws {
        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf",
            originalFilename: "source.pdf"
        ).uuidString.lowercased()

        XCTAssertTrue(FileManager.default.fileExists(atPath: self.rawURL(itemID: itemID, status: "pending").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.noteURL(itemID: itemID, status: "pending").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.descriptorURL(itemID: itemID, status: "pending").path))
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)

        let descriptor = try self.readDescriptor(itemID: itemID)
        XCTAssertEqual(descriptor.source, "document")
        XCTAssertEqual(descriptor.filename, "document.pdf")
        XCTAssertEqual(descriptor.contentType, "application/pdf")
        let note = try self.readNote(itemID: itemID, status: "pending")
        XCTAssertEqual(note["source"] as? String, "document")
    }

    @MainActor
    func testNoteWriteFailureRemovesRawAndThrows() async throws {
        let queue = self.makeQueue(
            fileManager: NoteWriteFailingFileManager(),
            ensureRegistered: { throw ImportQueueError.registrationUnavailable }
        )
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        do {
            _ = try await queue.enqueue(
                fileURL: source,
                source: "document",
                targetJournal: "home",
                contentType: "com.adobe.pdf"
            )
            XCTFail("Expected enqueue to throw")
        } catch ImportQueueError.writeFailed {
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(try self.directoryEntries(status: "pending"), [])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    @MainActor
    func testSaveThenStartFinalizesLedgerAndBackgroundCompletion() async throws {
        ImportQueueURLProtocol.handler = { request in
            switch request.url?.path {
            case "/app/import/api/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"path":"/imports/item-1","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)
                )
            case "/app/import/api/start":
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"status":"queued","task_id":"task-1"}"#.utf8)
                )
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))
        let completionCounter = ImportQueueCompletionCounter()
        queue.handleBackgroundURLSessionEvents {
            completionCounter.increment()
        }

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf",
            originalFilename: "source.pdf",
            originApp: "com.example.files"
        ).uuidString.lowercased()

        try await self.waitFor("save/start delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save", "/app/import/api/start"])

        let saveBody = String(decoding: try XCTUnwrap(ImportQueueURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(saveBody.contains(#"name="imported_via""#))
        XCTAssertTrue(saveBody.contains("mobile_share"))
        XCTAssertTrue(saveBody.contains(#"name="observer_handle""#))
        XCTAssertTrue(saveBody.contains("test-observer-key-abc"))
        XCTAssertTrue(saveBody.contains(#"name="file"; filename="document.pdf""#))
        XCTAssertFalse(saveBody.contains(#"name="day""#))
        XCTAssertFalse(saveBody.contains(#"name="segment""#))
        XCTAssertFalse(saveBody.contains(#"name="platform""#))
        XCTAssertFalse(saveBody.contains("item.json"))

        let startBody = try XCTUnwrap(JSONSerialization.jsonObject(with: ImportQueueURLProtocol.capturedBodies[1]) as? [String: Any])
        XCTAssertEqual(startBody["path"] as? String, "/imports/item-1")
        XCTAssertEqual(startBody["timestamp"] as? String, "2026-04-20T12:00:00Z")
        XCTAssertEqual(startBody["source"] as? String, "document")

        let ledger = try self.readLedger()
        XCTAssertEqual(ledger[itemID]?.serverPath, "/imports/item-1")
        XCTAssertEqual(ledger[itemID]?.serverTimestamp, "2026-04-20T12:00:00Z")
        XCTAssertEqual(ledger[itemID]?.filename, "source.pdf")
        XCTAssertEqual(ledger[itemID]?.originApp, "com.example.files")
        XCTAssertNotNil(ledger[itemID]?.itemTime)

        queue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testQuickTextSaveUsesTextFieldWithoutFilePart() async throws {
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"path":"/imports/text","timestamp":"2026-04-20T12:00:00Z","dedup":true}"#.utf8)
            )
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "note.txt", data: Data("  hello text  ".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "quick",
            targetJournal: "home",
            contentType: "public.plain-text",
            originalFilename: "note.txt"
        )

        try await self.waitFor("text dedup delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        let body = String(decoding: try XCTUnwrap(ImportQueueURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="text""#))
        XCTAssertTrue(body.contains("  hello text  "))
        XCTAssertFalse(body.contains(#"name="file""#))
    }

    @MainActor
    func testPersistedSaveResultResumesAtStartWithoutRegistrationOrResave() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"path":"/imports/saved","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)
            .write(to: self.saveResultURL(itemID: itemID, status: "pending"), options: .atomic)
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/start")
            return (Self.response(for: request, statusCode: 200), Data("ok".utf8))
        }
        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })

        await queue.resumeFromDisk()

        try await self.waitFor("saved item start") {
            queue.pendingCount == 0 && ImportQueueURLProtocol.callCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/start"])
        XCTAssertEqual(try self.readLedger()[itemID]?.serverPath, "/imports/saved")
    }

    @MainActor
    func testDedupSaveFinalizesWithoutStart() async throws {
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"path":"/imports/dedup","timestamp":"2026-04-20T12:00:00Z","dedup":true}"#.utf8)
            )
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("dedup delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
        XCTAssertEqual(try self.readLedger()[itemID]?.serverPath, "/imports/dedup")
    }

    @MainActor
    func testSaveSuccessResetsRetryBudgetBeforeStart() async throws {
        let saveFailures = OSAllocatedUnfairLock<Int>(initialState: 0)
        let startFailures = OSAllocatedUnfairLock<Int>(initialState: 0)
        ImportQueueURLProtocol.handler = { request in
            switch request.url?.path {
            case "/app/import/api/save":
                if saveFailures.withLock({ count in
                    count += 1
                    return count
                }) <= 4 {
                    return (Self.response(for: request, statusCode: 503), Data("save unavailable".utf8))
                }
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"path":"/imports/retry","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)
                )
            case "/app/import/api/start":
                if startFailures.withLock({ count in
                    count += 1
                    return count
                }) <= 4 {
                    return (Self.response(for: request, statusCode: 503), Data("start unavailable".utf8))
                }
                return (Self.response(for: request, statusCode: 200), Data("ok".utf8))
            default:
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let queue = self.makeQueue(retryDelays: [0, 0, 0, 0], maxAttempts: 5)
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("retry budget reset delivery", timeout: .seconds(4)) {
            queue.pendingCount == 0 && queue.failedCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(saveFailures.withLock { $0 }, 5)
        XCTAssertEqual(startFailures.withLock { $0 }, 5)
    }

    @MainActor
    func testRepeatedSaveFailuresMoveToFailed() async throws {
        ImportQueueURLProtocol.handler = { request in
            (Self.response(for: request, statusCode: 503), Data("service unavailable".utf8))
        }
        let queue = self.makeQueue(retryDelays: [0, 0], maxAttempts: 3)
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("failed import") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 3)
    }

    @MainActor
    func testLedgerPreventsResendOnResume() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try self.writeLedger([
            itemID: TestLedgerEntry(
                itemID: itemID,
                basis: "sent",
                contentType: "com.adobe.pdf",
                targetJournal: "home",
                serverPath: "/imports/existing",
                serverTimestamp: "2026-04-20T12:00:00Z",
                deliveredAt: Date(timeIntervalSince1970: 1)
            ),
        ])
        let queue = self.makeQueue()

        await queue.resumeFromDisk()

        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
    }

    @MainActor
    func testNilPortHoldsThenFlushesWhenPortAppears() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: nil)
        ImportQueueURLProtocol.handler = { request in
            switch request.url?.path {
            case "/app/import/api/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"path":"/imports/item","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)
                )
            case "/app/import/api/start":
                return (Self.response(for: request, statusCode: 200), Data("ok".utf8))
            default:
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let queue = self.makeQueue(localPortProvider: { localPort.withLock { $0 } })
        queue.lastError = "stale"
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)

        localPort.withLock { $0 = 7071 }
        await queue.resumeFromDisk()

        try await self.waitFor("nil-port import flush") {
            queue.pendingCount == 0 && ImportQueueURLProtocol.callCount == 2
        }
        XCTAssertNil(queue.lastError)
    }

    @MainActor
    func testOldDescriptorDecodeFailureMovesToFailedThroughFailurePath() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"day":"20260420","segment":"120000_0","filename":"document.pdf","content_type":"application/pdf"}"#.utf8)
            .write(to: self.descriptorURL(itemID: itemID, status: "pending"), options: .atomic)
        let queue = self.makeQueue(maxAttempts: 1)

        await queue.resumeFromDisk()

        try await self.waitFor("old descriptor failed") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
    }

    @MainActor
    private func makeQueue(
        fileManager: FileManager = .default,
        retryDelays: [UInt64] = [0],
        maxAttempts: Int = 5,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = { "test-observer-key-abc" },
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { 7071 },
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_713_624_000) }
    ) -> ImportQueue {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportQueueURLProtocol.self]
        return ImportQueue(
            cacheRootURL: self.tempDirectory,
            fileManager: fileManager,
            sessionConfiguration: configuration,
            ensureRegistered: ensureRegistered,
            isJournalConfigured: isJournalConfigured,
            localPortProvider: localPortProvider,
            retryDelays: retryDelays,
            maxAttempts: maxAttempts,
            sleep: sleep,
            startPathMonitor: false,
            now: now
        )
    }

    private func makeSourceFile(named name: String, data: Data) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeLocalItem(status: String) throws -> String {
        let itemID = UUID().uuidString.lowercased()
        let directory = self.tempDirectory
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: self.rawURL(itemID: itemID, status: status))
        let note = #"{"schema":"solstone.source.item/1","source":"document","origin_app":null,"content_type":"com.adobe.pdf","filename":"source.pdf","bytes":3,"basis":"sent","item_time":"2026-06-02T00:00:00.000Z","target_journal":"home","kind":"raw","item_id":"\#(itemID)"}"#
        try Data(note.utf8).write(to: self.noteURL(itemID: itemID, status: status))
        let request = #"{"source":"document","filename":"document.pdf","content_type":"application/pdf"}"#
        try Data(request.utf8).write(to: self.descriptorURL(itemID: itemID, status: status))
        return itemID
    }

    private func pendingItemDirectory(itemID: String) -> URL {
        self.tempDirectory
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
    }

    private func directoryEntries(status: String) throws -> [URL] {
        let directory = self.tempDirectory.appendingPathComponent(status, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private func rawURL(itemID: String, status: String) -> URL {
        self.itemDirectory(itemID: itemID, status: status).appendingPathComponent("raw.bin")
    }

    private func noteURL(itemID: String, status: String) -> URL {
        self.itemDirectory(itemID: itemID, status: status).appendingPathComponent("item.json")
    }

    private func descriptorURL(itemID: String, status: String) -> URL {
        self.itemDirectory(itemID: itemID, status: status).appendingPathComponent("request.json")
    }

    private func saveResultURL(itemID: String, status: String) -> URL {
        self.itemDirectory(itemID: itemID, status: status).appendingPathComponent("save.json")
    }

    private func itemDirectory(itemID: String, status: String) -> URL {
        self.tempDirectory
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
    }

    private func readDescriptor(itemID: String) throws -> TestRequestDescriptor {
        try JSONDecoder().decode(TestRequestDescriptor.self, from: Data(contentsOf: self.descriptorURL(itemID: itemID, status: "pending")))
    }

    private func readNote(itemID: String, status: String) throws -> [String: Any] {
        let data = try Data(contentsOf: self.noteURL(itemID: itemID, status: status))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func readLedger() throws -> [String: TestLedgerEntry] {
        let url = self.tempDirectory.appendingPathComponent("ledger.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: TestLedgerEntry].self, from: Data(contentsOf: url))
    }

    private func writeLedger(_ ledger: [String: TestLedgerEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: self.tempDirectory.appendingPathComponent("ledger.json"), options: .atomic)
    }

    @MainActor private func waitFor(_ label: String, timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

private struct TestRequestDescriptor: Decodable {
    let source: String
    let filename: String
    let contentType: String

    enum CodingKeys: String, CodingKey {
        case source
        case filename
        case contentType = "content_type"
    }
}

private struct TestLedgerEntry: Codable, Equatable {
    let itemID: String
    let basis: String
    let contentType: String
    let targetJournal: String
    let serverPath: String?
    let serverTimestamp: String?
    let deliveredAt: Date
    let filename: String?
    let originApp: String?
    let itemTime: String?

    init(
        itemID: String,
        basis: String,
        contentType: String,
        targetJournal: String,
        serverPath: String?,
        serverTimestamp: String?,
        deliveredAt: Date,
        filename: String? = nil,
        originApp: String? = nil,
        itemTime: String? = nil
    ) {
        self.itemID = itemID
        self.basis = basis
        self.contentType = contentType
        self.targetJournal = targetJournal
        self.serverPath = serverPath
        self.serverTimestamp = serverTimestamp
        self.deliveredAt = deliveredAt
        self.filename = filename
        self.originApp = originApp
        self.itemTime = itemTime
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case basis
        case contentType = "content_type"
        case targetJournal = "target_journal"
        case serverPath = "server_path"
        case serverTimestamp = "server_timestamp"
        case deliveredAt = "delivered_at"
        case filename
        case originApp = "origin_app"
        case itemTime = "item_time"
    }
}

private final class NoteWriteFailingFileManager: FileManager, @unchecked Sendable {
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.hasSuffix("item.json") {
            return false
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private final class ImportQueueCompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }

    func value() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }
}

private final class ImportQueueURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private static let pathsBox = OSAllocatedUnfairLock<[String]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }
    static var callCount: Int {
        get { self.callCountBox.withLock { $0 } }
        set { self.callCountBox.withLock { $0 = newValue } }
    }
    static var capturedBodies: [Data] {
        get { self.bodiesBox.withLock { $0 } }
        set { self.bodiesBox.withLock { $0 = newValue } }
    }
    static var capturedPaths: [String] {
        get { self.pathsBox.withLock { $0 } }
        set { self.pathsBox.withLock { $0 = newValue } }
    }

    static func reset() {
        self.handler = nil
        self.callCount = 0
        self.capturedBodies = []
        self.capturedPaths = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        XCTAssertNil(self.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotEqual(self.request.url?.path, "/app/observer/ingest")
        Self.callCountBox.withLock { $0 += 1 }
        Self.pathsBox.withLock { $0.append(self.request.url?.path ?? "") }
        let body = Self.bodyData(from: self.request)
        Self.bodiesBox.withLock { $0.append(body) }
        guard let handler = Self.handler else {
            XCTFail("ImportQueueURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var output = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            output.append(buffer, count: read)
        }
        return output
    }
}
