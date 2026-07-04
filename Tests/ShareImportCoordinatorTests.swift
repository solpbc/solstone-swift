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
        XCTAssertNil(result.failureMessage)
        let itemIDString = itemID.uuidString.lowercased()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueRoot.appendingPathComponent("pending/\(itemIDString)/raw.bin").path))
        let itemJSONURL = queueRoot.appendingPathComponent("pending/\(itemIDString)/item.json")
        let itemJSONData = try Data(contentsOf: itemJSONURL)
        let itemJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: itemJSONData) as? [String: Any])
        XCTAssertEqual(itemJSON["source"] as? String, "document")
        XCTAssertEqual(itemJSON["target_journal"] as? String, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
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
            provider: StubShareItemProvider(contentType: "public.url", filename: "link.url", fileURL: nil),
            expectedFailure: .unsupported
        )
    }

    @MainActor
    func testUnsupportedImageSubtypeShowsCantSaveAndNothingEnqueued() async throws {
        try await self.assertPreEnqueueFailure(
            provider: StubShareItemProvider(contentType: "com.microsoft.bmp", filename: "image.bmp", fileURL: nil),
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
        _ = FileManager.default.createFile(atPath: source.path, contents: Data())
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
    func testPlainTextWhitespaceDropsWithoutEnqueue() async throws {
        let queue = CapturingShareImportQueue()
        let recorder = ShareImportEventRecorder()
        let coordinator = ShareImportCoordinator(queue: queue) { event in
            recorder.append(event)
        }
        let provider = StubShareItemProvider(contentType: "public.plain-text", filename: "note.txt", fileURL: nil, text: " \n\t ")

        let result = await coordinator.accept(provider: provider)

        XCTAssertEqual(result, .dropped)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(queue.enqueueCallCount, 0)
        XCTAssertEqual(recorder.events(), [.resolved])
    }

    @MainActor
    func testPlainTextPreservesOriginalTextAndEnqueuesQuick() async throws {
        let queue = CapturingShareImportQueue()
        let recorder = ShareImportEventRecorder()
        let coordinator = ShareImportCoordinator(queue: queue) { event in
            recorder.append(event)
        }
        let provider = StubShareItemProvider(contentType: "public.plain-text", filename: "note.txt", fileURL: nil, text: "  hello  ")

        let result = await coordinator.accept(provider: provider)

        guard case .success = result else {
            XCTFail("Expected success")
            return
        }
        XCTAssertEqual(queue.lastSource, "quick")
        XCTAssertEqual(queue.lastContentType, "public.plain-text")
        XCTAssertEqual(queue.lastOriginalFilename, "note.txt")
        XCTAssertEqual(queue.lastFileText, "  hello  ")
        XCTAssertEqual(Array(recorder.events().prefix(3)), [.resolved, .precheckPassed, .enqueueStarted])
    }

    @MainActor
    func testBatchAcceptReturnsOrderedPerItemResults() async throws {
        let queue = CapturingShareImportQueue()
        let coordinator = ShareImportCoordinator(queue: queue)
        let image = try self.makeFile(named: "image.jpg", data: Data("image".utf8))
        let providers: [any ShareItemProvider] = [
            StubShareItemProvider(contentType: "public.jpeg", filename: "image.jpg", fileURL: image),
            StubShareItemProvider(contentType: "public.url", filename: "link.url", fileURL: nil),
            StubShareItemProvider(contentType: "public.plain-text", filename: "note.txt", fileURL: nil, text: " \n\t "),
        ]

        let results = await coordinator.accept(providers: providers)

        XCTAssertEqual(results.count, 3)
        guard case .success = results[0] else {
            XCTFail("Expected first batch result to succeed")
            return
        }
        XCTAssertEqual(results[1], .failure(.unsupported))
        XCTAssertEqual(results[2], .dropped)
        XCTAssertEqual(queue.enqueueCallCount, 1)
    }

    @MainActor
    func testBatchStatusExactStrings() {
        XCTAssertEqual(ShareImportCopy.batchStatus(saved: 1, failed: 0), "saved")
        XCTAssertEqual(ShareImportCopy.batchStatus(saved: 3, failed: 0), "saved 3 of 3")
        let partial = ShareImportCopy.batchStatus(saved: 2, failed: 1)
        XCTAssertEqual(partial, "2 saved · 1 couldn't")
        let partialBytes = Array(partial.utf8)
        XCTAssertTrue(partialBytes.indices.dropLast().contains { partialBytes[$0] == 0xC2 && partialBytes[$0 + 1] == 0xB7 })
        XCTAssertEqual(ShareImportCopy.batchStatus(saved: 0, failed: 3), "couldn't save 3 items — nothing was added.")
        XCTAssertEqual(ShareImportCopy.batchStatus(saved: 0, failed: 1), "")

        let id = UUID()
        let counts = ShareImportCopy.batchCounts(for: [
            .success(id),
            .failure(.unsupported),
            .dropped,
            .success(UUID()),
        ])
        XCTAssertEqual(counts.saved, 2)
        XCTAssertEqual(counts.failed, 1)
    }

    @MainActor
    func testScratchParentRemovedAfterEnqueue() async throws {
        let fileManager = TemporaryDirectoryFileManager(temporaryDirectory: self.tempDirectory)
        let queue = CapturingShareImportQueue()
        let coordinator = ShareImportCoordinator(queue: queue, fileManager: fileManager)
        let provider = StubShareItemProvider(contentType: "public.plain-text", filename: "note.txt", fileURL: nil, text: "hello")

        let result = await coordinator.accept(provider: provider)

        guard case .success = result else {
            XCTFail("Expected text import to succeed")
            return
        }
        let scratchRoot = self.tempDirectory.appendingPathComponent("SolstoneShareImport", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: scratchRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries, [])
    }

    @MainActor
    func testProviderCleanupScratchInvokedAfterEnqueue() async throws {
        let source = try self.makeFile(named: "share.pdf", data: Data("pdf".utf8))
        let provider = StubShareItemProvider(contentType: "com.adobe.pdf", filename: "share.pdf", fileURL: source)
        let queue = CapturingShareImportQueue()
        var enqueueCompletedBeforeCleanup = false
        queue.onEnqueue = {
            XCTAssertEqual(provider.cleanupCallCount, 0)
            enqueueCompletedBeforeCleanup = true
        }
        let coordinator = ShareImportCoordinator(queue: queue)

        let result = await coordinator.accept(provider: provider)

        guard case .success = result else {
            XCTFail("Expected file import to succeed")
            return
        }
        XCTAssertTrue(enqueueCompletedBeforeCleanup)
        XCTAssertEqual(provider.cleanupCallCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testContentTypesMapToImporterSources() async throws {
        let cases: [(String, String)] = [
            ("com.adobe.pdf", "document"),
            ("public.jpeg", "image"),
            ("public.png", "image"),
            ("org.webmproject.webp", "image"),
            ("public.tiff", "image"),
            ("com.compuserve.gif", "image"),
            ("public.m4a-audio", "audio"),
            ("public.mp3", "audio"),
        ]

        for (contentType, expectedSource) in cases {
            let queue = CapturingShareImportQueue()
            let coordinator = ShareImportCoordinator(queue: queue)
            let source = try self.makeFile(named: "\(UUID().uuidString).bin", data: Data("data".utf8))
            let provider = StubShareItemProvider(contentType: contentType, filename: "shared.bin", fileURL: source)

            let result = await coordinator.accept(provider: provider)

            guard case .success = result else {
                XCTFail("Expected success for \(contentType)")
                continue
            }
            XCTAssertEqual(queue.lastSource, expectedSource)
        }
    }

    @MainActor
    func testHEICTranscodeFailureShowsUndecodableAndNothingEnqueued() async throws {
        let queue = CapturingShareImportQueue()
        let recorder = ShareImportEventRecorder()
        let coordinator = ShareImportCoordinator(queue: queue) { event in
            recorder.append(event)
        }
        let source = try self.makeFile(named: "bad.heic", data: Data("not an image".utf8))
        let provider = StubShareItemProvider(contentType: "public.heic", filename: "bad.heic", fileURL: source)

        let result = await coordinator.accept(provider: provider)

        XCTAssertEqual(result, .failure(.undecodable))
        XCTAssertEqual(result.failureMessage, "couldn't save this — couldn't read the image. nothing was added.")
        XCTAssertEqual(queue.enqueueCallCount, 0)
        XCTAssertEqual(recorder.events(), [.resolved, .failed(.undecodable)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try self.assertQueueDirectoriesEmpty(root: queueRoot)
    }

    @MainActor
    private func assertPreEnqueueFailure(
        provider: StubShareItemProvider,
        expectedFailure: ShareImportFailure
    ) async throws {
        let queue = CapturingShareImportQueue()
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
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        }
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
    let text: String
    let loadError: Error?
    private(set) var cleanupCallCount = 0

    init(
        contentType: String?,
        filename: String?,
        fileURL: URL?,
        text: String = "",
        loadError: Error? = nil
    ) {
        self.contentType = contentType
        self.filename = filename
        self.fileURL = fileURL
        self.text = text
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

    func loadText() async throws -> String {
        if let loadError {
            throw loadError
        }
        return self.text
    }

    func cleanupScratch() {
        self.cleanupCallCount += 1
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
        targetJournal: String,
        contentType: String,
        originalFilename: String?,
        originApp: String?
    ) async throws -> UUID {
        self.enqueueCallCount += 1
        return try await self.base.enqueue(
            fileURL: fileURL,
            source: source,
            targetJournal: targetJournal,
            contentType: contentType,
            originalFilename: originalFilename,
            originApp: originApp
        )
    }
}

@MainActor
private final class CapturingShareImportQueue: ShareImportQueueing {
    var enqueueCallCount = 0
    var lastSource: String?
    var lastContentType: String?
    var lastOriginalFilename: String?
    var lastFileText: String?
    var onEnqueue: (@MainActor () -> Void)?

    func enqueue(
        fileURL: URL,
        source: String,
        targetJournal: String,
        contentType: String,
        originalFilename: String?,
        originApp: String?
    ) async throws -> UUID {
        self.enqueueCallCount += 1
        self.lastSource = source
        self.lastContentType = contentType
        self.lastOriginalFilename = originalFilename
        self.lastFileText = try? String(contentsOf: fileURL, encoding: .utf8)
        self.onEnqueue?()
        return UUID()
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

private final class TemporaryDirectoryFileManager: FileManager, @unchecked Sendable {
    private let directory: URL

    init(temporaryDirectory: URL) {
        self.directory = temporaryDirectory
        super.init()
    }

    override var temporaryDirectory: URL {
        self.directory
    }
}

private final class ShareImportEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ShareImportEvent] = []

    func append(_ event: ShareImportEvent) {
        self.lock.lock()
        self.recorded.append(event)
        self.lock.unlock()
    }

    func events() -> [ShareImportEvent] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }
}
