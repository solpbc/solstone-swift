// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ShareImportCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testDurableSaveBeforeCommitEventSuccessOrdering() async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let queue = ImportQueue(
            cacheRootURL: queueRoot,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable },
            startPathMonitor: false
        )
        let source = try self.makeFile(named: "share.pdf", data: Data("pdf".utf8))
        let provider = StubShareItemProvider(contentType: "com.adobe.pdf", filename: "share.pdf", fileURL: source)
        let recorder = ShareImportEventRecorder()
        let coordinator = ShareImportCoordinator(queue: queue) { event in
            recorder.append(event)
        }

        let result = await coordinator.accept(provider: provider)
        coordinator.saveCommitted()

        guard case .success(let itemID) = result else {
            XCTFail("Expected success")
            return
        }
        // Success carries no owner-facing message API; failures remain message-bearing.
        XCTAssertNil(result.failureMessage)
        let itemIDString = itemID.uuidString.lowercased()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueRoot.appendingPathComponent("pending/\(itemIDString)/raw.bin").path))
        let itemJSONURL = queueRoot.appendingPathComponent("pending/\(itemIDString)/item.json")
        let itemJSONData = try Data(contentsOf: itemJSONURL)
        let itemJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: itemJSONData) as? [String: Any])
        XCTAssertEqual(itemJSON["target_journal"] as? String, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(recorder.events(), [
            .resolved,
            .precheckPassed,
            .enqueueStarted,
            .enqueueSucceeded(itemID),
            .saveCommitted,
        ])
    }

    @MainActor
    func testUnsupportedRepresentationShowsCantSaveAndNothingEnqueued() async throws {
        try await self.assertPreEnqueueFailure(
            provider: StubShareItemProvider(contentType: "public.plain-text", filename: "note.txt", fileURL: nil),
            expectedFailure: .unsupported
        )
    }

    @MainActor
    func testUnreadableLoadFailureShowsCantSaveAndNothingEnqueued() async throws {
        try await self.assertPreEnqueueFailure(
            provider: StubShareItemProvider(contentType: "com.adobe.pdf", filename: "share.pdf", fileURL: nil, loadError: StubProviderError.loadFailed),
            expectedFailure: .unreadable
        )
    }

    @MainActor
    func testOversizedShowsCantSaveAndNothingEnqueued() async throws {
        let source = self.tempDirectory.appendingPathComponent("large.pdf")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ShareImportCoordinator.oversizedByteLimit + 1))
        try handle.close()

        try await self.assertPreEnqueueFailure(
            provider: StubShareItemProvider(contentType: "com.adobe.pdf", filename: "large.pdf", fileURL: source),
            expectedFailure: .oversized
        )
    }

    @MainActor
    func testProtectedFileShowsCantSaveAndNothingEnqueued() async throws {
        let directoryURL = self.tempDirectory.appendingPathComponent("protected.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        try await self.assertPreEnqueueFailure(
            provider: StubShareItemProvider(contentType: "com.adobe.pdf", filename: "protected.pdf", fileURL: directoryURL),
            expectedFailure: .protected
        )
    }

    @MainActor
    func testEnqueueThrowShowsCantSaveAfterCleanupAndNoSavedCopy() async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("late-failure-queue", isDirectory: true)
        let realQueue = ImportQueue(
            cacheRootURL: queueRoot,
            fileManager: CoordinatorNoteWriteFailingFileManager(),
            ensureRegistered: { throw ImportQueueError.registrationUnavailable },
            startPathMonitor: false
        )
        let queue = RecordingShareImportQueue(base: realQueue)
        let source = try self.makeFile(named: "share.pdf", data: Data("pdf".utf8))
        let provider = StubShareItemProvider(contentType: "com.adobe.pdf", filename: "share.pdf", fileURL: source)
        let recorder = ShareImportEventRecorder()
        let coordinator = ShareImportCoordinator(queue: queue) { event in
            recorder.append(event)
        }

        let result = await coordinator.accept(provider: provider)

        XCTAssertEqual(result, .failure(.unreadable))
        XCTAssertEqual(result.failureMessage, "couldn't save this — couldn't read it. nothing was added.")
        XCTAssertEqual(queue.enqueueCallCount, 1)
        XCTAssertEqual(recorder.events(), [
            .resolved,
            .precheckPassed,
            .enqueueStarted,
            .failed(.unreadable),
        ])
        XCTAssertFalse(recorder.events().contains(.saveCommitted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try self.assertQueueDirectoriesEmpty(root: queueRoot)
    }

    @MainActor
    private func assertPreEnqueueFailure(
        provider: StubShareItemProvider,
        expectedFailure: ShareImportFailure
    ) async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        let realQueue = ImportQueue(
            cacheRootURL: queueRoot,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable },
            startPathMonitor: false
        )
        let queue = RecordingShareImportQueue(base: realQueue)
        let recorder = ShareImportEventRecorder()
        let coordinator = ShareImportCoordinator(queue: queue) { event in
            recorder.append(event)
        }

        let result = await coordinator.accept(provider: provider)

        XCTAssertEqual(result, .failure(expectedFailure))
        XCTAssertEqual(result.failureMessage, "couldn't save this — \(expectedFailure.plainReason). nothing was added.")
        XCTAssertEqual(queue.enqueueCallCount, 0)
        XCTAssertFalse(recorder.events().contains(.enqueueStarted))
        XCTAssertTrue(recorder.events().contains(.failed(expectedFailure)))
        if let fileURL = provider.fileURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
        try self.assertQueueDirectoriesEmpty(root: queueRoot)
    }

    private func makeFile(named name: String, data: Data) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func assertQueueDirectoriesEmpty(root: URL) throws {
        for subdirectory in ["pending", "failed"] {
            let directory = root.appendingPathComponent(subdirectory, isDirectory: true)
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertTrue(entries.isEmpty, "\(subdirectory) should be empty")
        }
    }
}

@MainActor
private final class StubShareItemProvider: ShareItemProvider {
    let contentType: String?
    let filename: String?
    let fileURL: URL?
    let loadError: Error?

    init(contentType: String?, filename: String?, fileURL: URL?, loadError: Error? = nil) {
        self.contentType = contentType
        self.filename = filename
        self.fileURL = fileURL
        self.loadError = loadError
    }

    func registeredContentType() -> String? {
        self.contentType
    }

    func suggestedFilename() -> String? {
        self.filename
    }

    func loadFileRepresentation() async throws -> URL {
        if let loadError {
            throw loadError
        }
        guard let fileURL else {
            throw StubProviderError.loadFailed
        }
        return fileURL
    }
}

@MainActor
private final class RecordingShareImportQueue: ShareImportQueueing {
    private let base: any ShareImportQueueing
    var enqueueCallCount = 0

    init(base: any ShareImportQueueing) {
        self.base = base
    }

    func enqueue(
        fileURL: URL,
        source: String,
        stream: String,
        targetJournal: String,
        contentType: String,
        originalFilename: String?,
        originApp: String?
    ) async throws -> UUID {
        self.enqueueCallCount += 1
        return try await self.base.enqueue(
            fileURL: fileURL,
            source: source,
            stream: stream,
            targetJournal: targetJournal,
            contentType: contentType,
            originalFilename: originalFilename,
            originApp: originApp
        )
    }
}

private enum StubProviderError: Error {
    case loadFailed
}

private final class CoordinatorNoteWriteFailingFileManager: FileManager, @unchecked Sendable {
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.hasSuffix("item.json") {
            return false
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private final class ShareImportEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ShareImportEvent] = []

    func append(_ event: ShareImportEvent) {
        self.lock.lock()
        self.storage.append(event)
        self.lock.unlock()
    }

    func events() -> [ShareImportEvent] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}
