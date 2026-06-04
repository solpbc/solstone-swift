// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import Network
import os
import XCTest

nonisolated final class ImportQueueTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportQueueTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        ImportQueueURLProtocol.handler = nil
        ImportQueueURLProtocol.callCount = 0
        ImportQueueURLProtocol.capturedBodies = []
        ImportQueueURLProtocol.cancelledCount = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        ImportQueueURLProtocol.handler = nil
        ImportQueueURLProtocol.callCount = 0
        ImportQueueURLProtocol.capturedBodies = []
        ImportQueueURLProtocol.cancelledCount = 0
        super.tearDown()
    }

    @MainActor
    func testAppGroupContainerIdentifierAndImportQueueSubpath() throws {
        XCTAssertEqual(AppGroupContainer.identifier, "group.app.solstone.swift")

        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.tempDirectory.appendingPathComponent("pending").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.tempDirectory.appendingPathComponent("failed").path))

        if let appGroupRoot = try? AppGroupContainer.rootURL() {
            XCTAssertTrue(appGroupRoot.path.contains("group.app.solstone.swift") || !appGroupRoot.path.isEmpty)
        }
    }

    func testBackgroundConfigurationUsesSharedContainer() {
        let config = ImportQueue.makeBackgroundConfiguration()
        XCTAssertEqual(config.identifier, ImportQueue.backgroundSessionIdentifier)
        XCTAssertEqual(config.sharedContainerIdentifier, AppGroupContainer.identifier)
        XCTAssertTrue(config.waitsForConnectivity)
    }

    @MainActor
    func testEnqueueWritesPendingItemPair() async throws {
        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf",
            originalFilename: "source.pdf"
        )

        let itemIDString = itemID.uuidString.lowercased()
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.rawURL(itemID: itemIDString, status: "pending").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.noteURL(itemID: itemIDString, status: "pending").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.descriptorURL(itemID: itemIDString, status: "pending").path))
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
    }

    @MainActor
    func testNoteWriteFailureRemovesRawAndThrows() async throws {
        let failingFileManager = NoteWriteFailingFileManager()
        let queue = self.makeQueue(
            fileManager: failingFileManager,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable }
        )
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        do {
            _ = try await queue.enqueue(
                fileURL: source,
                source: "share-extension",
                stream: "import.share",
                targetJournal: "home",
                contentType: "com.adobe.pdf"
            )
            XCTFail("Expected enqueue to throw")
        } catch ImportQueueError.writeFailed {
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        let pending = self.tempDirectory.appendingPathComponent("pending", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    @MainActor
    func testResumeMovesIncompleteItemToFailed() async throws {
        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })
        let itemID = UUID().uuidString.lowercased()
        let itemDirectory = self.pendingItemDirectory(itemID: itemID)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: self.rawURL(itemID: itemID, status: "pending"))

        await queue.resumeFromDisk()

        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.failedItemDirectory(itemID: itemID).path))
        XCTAssertEqual(queue.failedCount, 1)
    }

    @MainActor
    func testFrozenNoteExactOrderedBytesAndPopulatedValues() async throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_713_624_000.125)
        let fileManager = AttributeFileManager(attributes: [
            .modificationDate: modifiedAt,
            .size: NSNumber(value: 3),
        ])
        let queue = self.makeQueue(
            fileManager: fileManager,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable }
        )
        let source = try self.makeSourceFile(named: "photo.jpg", data: Data("img".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "daily",
            contentType: "public.jpeg",
            originalFilename: "photo.jpg",
            originApp: "com.example.photos"
        )

        let itemIDString = itemID.uuidString.lowercased()
        let note = try String(contentsOf: self.noteURL(itemID: itemIDString, status: "pending"), encoding: .utf8)
        let expected = #"{"schema":"solstone.source.item/1","source":"share-extension","origin_app":"com.example.photos","content_type":"public.jpeg","filename":"photo.jpg","bytes":3,"basis":"modified","item_time":"\#(Self.iso8601String(for: modifiedAt))","target_journal":"daily","kind":"raw","item_id":"\#(itemIDString)"}"#
        XCTAssertEqual(note, expected)
    }

    @MainActor
    func testShareItemSchemaAndImportShareRequest() async throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_713_624_000.125)
        let fileManager = AttributeFileManager(attributes: [
            .modificationDate: modifiedAt,
            .size: NSNumber(value: 5),
        ])
        let queue = self.makeQueue(
            fileManager: fileManager,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable }
        )
        let source = try self.makeSourceFile(named: "share.pdf", data: Data("abcde".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share",
            stream: "import.share",
            targetJournal: "sol",
            contentType: "com.adobe.pdf",
            originalFilename: "share.pdf"
        ).uuidString.lowercased()

        let noteData = try Data(contentsOf: self.noteURL(itemID: itemID, status: "pending"))
        let note = try XCTUnwrap(JSONSerialization.jsonObject(with: noteData) as? [String: Any])
        XCTAssertEqual(note["schema"] as? String, "solstone.source.item/1")
        XCTAssertEqual(note["source"] as? String, "share")
        XCTAssertTrue(note["origin_app"] is NSNull)
        XCTAssertEqual(note["content_type"] as? String, "com.adobe.pdf")
        XCTAssertEqual(note["filename"] as? String, "share.pdf")
        XCTAssertEqual(note["bytes"] as? Int, 5)
        XCTAssertTrue(["modified", "created", "sent"].contains(try XCTUnwrap(note["basis"] as? String)))
        XCTAssertEqual(note["target_journal"] as? String, "sol")

        let descriptor = try self.readDescriptor(itemID: itemID)
        XCTAssertEqual(descriptor.stream, "import.share")
        XCTAssertEqual(descriptor.filename, "document.pdf")
        XCTAssertEqual(descriptor.contentType, "application/pdf")
    }

    @MainActor
    func testPlacementBasisModifiedCreatedAndSent() async throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let createdAt = Date(timeIntervalSince1970: 1_713_625_000)
        let sentAt = Date(timeIntervalSince1970: 1_713_626_000)

        let modifiedID = try await self.enqueueForPlacement(attributes: [.modificationDate: modifiedAt, .size: NSNumber(value: 1)], now: sentAt)
        let createdID = try await self.enqueueForPlacement(attributes: [.creationDate: createdAt, .size: NSNumber(value: 1)], now: sentAt)
        let sentID = try await self.enqueueForPlacement(attributes: [.size: NSNumber(value: 1)], now: sentAt)

        XCTAssertEqual(try self.noteValue(itemID: modifiedID, key: "basis"), "modified")
        XCTAssertEqual(try self.noteValue(itemID: modifiedID, key: "item_time"), Self.iso8601String(for: modifiedAt))
        XCTAssertEqual(try self.noteValue(itemID: createdID, key: "basis"), "created")
        XCTAssertEqual(try self.noteValue(itemID: createdID, key: "item_time"), Self.iso8601String(for: createdAt))
        XCTAssertEqual(try self.noteValue(itemID: sentID, key: "basis"), "sent")
        XCTAssertEqual(try self.noteValue(itemID: sentID, key: "item_time"), Self.iso8601String(for: sentAt))
    }

    @MainActor
    func testRawFilenameMapping() async throws {
        let cases: [(String, String, String)] = [
            ("public.mpeg-4-audio", "audio.m4a", "audio/mp4"),
            ("com.adobe.pdf", "document.pdf", "application/pdf"),
            ("public.jpeg", "image.jpg", "image/jpeg"),
            ("public.png", "image.png", "image/png"),
            ("public.heic", "image.heic", "image/heic"),
            ("com.compuserve.gif", "image.gif", "image/gif"),
            ("org.webmproject.webp", "image.webp", "image/webp"),
            ("public.tiff", "image.tiff", "image/tiff"),
            ("unknown.type", "item.bin", "application/octet-stream"),
        ]
        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })

        for (contentType, filename, mimeType) in cases {
            let source = try self.makeSourceFile(named: "\(UUID().uuidString).bin", data: Data("x".utf8))
            let itemID = try await queue.enqueue(
                fileURL: source,
                source: "share-extension",
                stream: "import.share",
                targetJournal: "home",
                contentType: contentType
            ).uuidString.lowercased()
            let descriptor = try self.readDescriptor(itemID: itemID)
            XCTAssertEqual(descriptor.filename, filename)
            XCTAssertEqual(descriptor.contentType, mimeType)
        }
    }

    @MainActor
    func testRetryRebuildsIdenticalMultipartBytes() async throws {
        ImportQueueURLProtocol.handler = { request in
            if ImportQueueURLProtocol.callCount == 1 {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data("service unavailable".utf8)
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok","segment":"120000_0"}"#.utf8)
            )
        }
        let queue = self.makeQueue(retryDelays: [0])
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("retry delivery") {
            ImportQueueURLProtocol.callCount >= 2 && queue.pendingCount == 0
        }
        XCTAssertGreaterThanOrEqual(ImportQueueURLProtocol.capturedBodies.count, 2)
        XCTAssertEqual(ImportQueueURLProtocol.capturedBodies[0], ImportQueueURLProtocol.capturedBodies[1])
        let body = String(decoding: ImportQueueURLProtocol.capturedBodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"day\""))
        XCTAssertTrue(body.contains("name=\"segment\""))
        XCTAssertTrue(body.contains("name=\"platform\""))
        XCTAssertTrue(body.contains("name=\"meta\""))
        XCTAssertTrue(body.contains(#"{"stream":"import.share"}"#))
        XCTAssertTrue(body.contains("filename=\"document.pdf\""))
        XCTAssertTrue(body.contains("filename=\"item.json\""))
    }

    @MainActor
    func testShareUploadSuccessFinalizesLedgerAndBackgroundCompletion() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok","segment":"120000_0"}"#.utf8)
            )
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))
        let completionCounter = ImportQueueCompletionCounter()
        queue.handleBackgroundURLSessionEvents {
            completionCounter.increment()
        }

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf",
            originalFilename: "source.pdf",
            originApp: "com.example.files"
        ).uuidString.lowercased()

        try await self.waitFor("share delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        let ledger = try self.readLedger()
        XCTAssertEqual(ledger[itemID]?.stream, "import.share")
        XCTAssertEqual(ledger[itemID]?.filename, "source.pdf")
        XCTAssertEqual(ledger[itemID]?.originApp, "com.example.files")
        XCTAssertNotNil(ledger[itemID]?.itemTime)
        let body = String(decoding: try XCTUnwrap(ImportQueueURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains(#"{"stream":"import.share"}"#))
        queue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testShareUploadFailureMovesToFailedAndBackgroundCompletion() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("service unavailable".utf8)
            )
        }
        let queue = self.makeQueue(retryDelays: [0], maxAttempts: 1)
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))
        let completionCounter = ImportQueueCompletionCounter()
        queue.handleBackgroundURLSessionEvents {
            completionCounter.increment()
        }

        _ = try await queue.enqueue(
            fileURL: source,
            source: "share",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("share failed") {
            queue.failedCount == 1
        }
        queue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testAny2xxLiteralOkIsDeliveredAndWritesLedger() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        let ledger = try self.readLedger()
        XCTAssertEqual(ledger[itemID]?.serverSegment, nil)
        XCTAssertEqual(ledger[itemID]?.stream, "import.share")
    }

    @MainActor
    func testDuplicateAndCollisionResponsesWriteServerSegment() async throws {
        try await self.assertServerSegment(
            response: #"{"status":"duplicate","existing_segment":"120000_1"}"#,
            expected: "120000_1"
        )
        try await self.assertServerSegment(
            response: #"{"status":"collision","segment":"120000_2"}"#,
            expected: "120000_2"
        )
    }

    @MainActor
    func testLedgerPreventsResendOnResume() async throws {
        let itemID = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: self.pendingItemDirectory(itemID: itemID), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: self.rawURL(itemID: itemID, status: "pending"))
        try Data("{}".utf8).write(to: self.noteURL(itemID: itemID, status: "pending"))
        try Data(#"{"day":"20260420","segment":"120000_0","stream":"import.share","filename":"document.pdf","content_type":"application/pdf"}"#.utf8)
            .write(to: self.descriptorURL(itemID: itemID, status: "pending"))
        try self.writeLedger([
            itemID: TestLedgerEntry(
                itemID: itemID,
                stream: "import.share",
                basis: "sent",
                contentType: "com.adobe.pdf",
                targetJournal: "home",
                serverDay: "20260420",
                serverSegment: nil,
                deliveredAt: Date(timeIntervalSince1970: 1)
            ),
        ])
        let queue = self.makeQueue()

        await queue.resumeFromDisk()

        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
    }

    @MainActor
    func testRepeatedTransientFailuresMoveToFailed() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("service unavailable".utf8)
            )
        }
        let queue = self.makeQueue(retryDelays: [0, 0, 0, 0])
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("failed import") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 5)
    }

    @MainActor
    func testKeyOrPortUnavailableLeavesPendingWithoutAttempts() async throws {
        let queue = self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable })
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        await queue.resumeFromDisk()
        await queue.resumeFromDisk()

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertNotNil(queue.lastError)
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
    }

    @MainActor
    func testJournalUnconfiguredLeavesPendingWithoutAttemptsAndClearsLastError() async throws {
        let sleepCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let registrationCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let queue = self.makeQueue(
            ensureRegistered: {
                registrationCalls.withLock { $0 += 1 }
                throw ImportQueueError.registrationUnavailable
            },
            isJournalConfigured: { false },
            localPortProvider: { 7071 },
            sleep: { _ in sleepCalls.withLock { $0 += 1 } }
        )
        queue.lastError = "stale"
        let source = try self.makeSourceFile(named: "unconfigured.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        await queue.resumeFromDisk()
        await queue.resumeFromDisk()

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(try self.directoryEntries(status: "failed"), [])
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
        XCTAssertEqual(registrationCalls.withLock { $0 }, 0)
        XCTAssertEqual(sleepCalls.withLock { $0 }, 0)
    }

    @MainActor
    func testNilPortHoldsThenFlushesWhenPortAppears() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let sleepCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let queue = self.makeQueue(
            isJournalConfigured: { true },
            localPortProvider: { localPort.withLock { $0 } },
            sleep: { _ in sleepCalls.withLock { $0 += 1 } }
        )
        queue.lastError = "stale"
        let source = try self.makeSourceFile(named: "nil-port.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
        XCTAssertEqual(sleepCalls.withLock { $0 }, 0)

        localPort.withLock { $0 = 7071 }
        await queue.resumeFromDisk()

        try await self.waitFor("nil-port import flush") {
            queue.pendingCount == 0 && ImportQueueURLProtocol.callCount == 1
        }
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertNil(queue.lastError)
    }

    @MainActor
    func testRequeueFailedItemMovesAndResendsFrozenBytes() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("service unavailable".utf8)
            )
        }
        let queue = self.makeQueue(retryDelays: [0, 0, 0, 0])
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        try await self.waitFor("failed import") {
            queue.failedCount == 1
        }
        let failedNote = try Data(contentsOf: self.noteURL(itemID: itemID.uuidString.lowercased(), status: "failed"))
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok","segment":"120000_0"}"#.utf8)
            )
        }
        ImportQueueURLProtocol.callCount = 0
        ImportQueueURLProtocol.capturedBodies = []

        try await queue.requeueFailedItem(itemID: itemID)

        try await self.waitFor("requeue delivery") {
            queue.pendingCount == 0 && ImportQueueURLProtocol.callCount == 1
        }
        let body = ImportQueueURLProtocol.capturedBodies.first ?? Data()
        XCTAssertNotNil(body.range(of: failedNote))
    }

    @MainActor
    func testRealConstructionWithTempRootDeliversEndToEnd() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok","segment":"120000_0"}"#.utf8)
            )
        }
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))
        let queue = self.makeQueue(fileManager: .default)

        _ = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("real construction delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertFalse(try self.readLedger().isEmpty)
    }

    @MainActor
    func testDeleteShareSourceCleanReceiptClearsLocalState() async throws {
        let pendingID = try self.writeLocalItem(status: "pending")
        let failedID = try self.writeLocalItem(status: "failed")
        try self.writeLedger([
            UUID().uuidString.lowercased(): Self.ledgerEntry(stream: "import.share"),
        ])
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/app/observer/source/import.share/test-observer-key-abc")
            return (Self.response(for: request, statusCode: 200), Self.deleteReceipt(originals: 3))
        }
        let queue = self.makeQueue()

        let result = await queue.deleteShareSource()

        guard case .confirmed(let receipt, let localNotRemoved) = result else {
            XCTFail("Expected confirmed result")
            return
        }
        XCTAssertEqual(receipt.removed.originals, 3)
        XCTAssertNil(receipt.removed.days)
        XCTAssertTrue(localNotRemoved.isEmpty)
        XCTAssertTrue(result.shouldFlipOff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: pendingID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.failedItemDirectory(itemID: failedID).path))
        XCTAssertEqual(try self.readLedger(), [:])
        XCTAssertEqual(queue.onThisPhoneSourceSnapshot(), .loaded(items: []))
    }

    @MainActor
    func testDeleteShareSourceDictTargetReceiptDecodesAndConfirms() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                Self.response(for: request, statusCode: 200),
                Self.deleteReceipt(originals: 4, days: 2)
            )
        }
        let queue = self.makeQueue()

        let result = await queue.deleteShareSource()

        guard case .confirmed(let receipt, _) = result else {
            XCTFail("Expected confirmed result")
            return
        }
        XCTAssertEqual(receipt.removed.originals, 4)
        XCTAssertEqual(receipt.removed.days, 2)
    }

    @MainActor
    func testDeleteShareSourceNotRemovedIsPartialAndStillClearsLocalState() async throws {
        let pendingID = try self.writeLocalItem(status: "pending")
        try self.writeLedger([
            UUID().uuidString.lowercased(): Self.ledgerEntry(stream: "import.share"),
        ])
        ImportQueueURLProtocol.handler = { request in
            (
                Self.response(for: request, statusCode: 200),
                Self.deleteReceipt(
                    originals: 1,
                    notRemoved: #"{"what":"history","plain_reason":"history rows stayed"}"#
                )
            )
        }
        let queue = self.makeQueue()

        let result = await queue.deleteShareSource()

        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.notRemovedIssues.map(\.plainReason), ["history rows stayed"])
        XCTAssertTrue(result.shouldFlipOff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: pendingID).path))
        XCTAssertEqual(try self.readLedger(), [:])
    }

    @MainActor
    func testDeleteShareSourceNotConfirmedIssuesDoNotDowngradeConfirmed() async throws {
        ImportQueueURLProtocol.handler = { request in
            (
                Self.response(for: request, statusCode: 200),
                Self.deleteReceipt(
                    originals: 2,
                    notConfirmed: #"{"what":"backups","plain_reason":"can't confirm backups"}"#
                )
            )
        }
        let queue = self.makeQueue()

        let result = await queue.deleteShareSource()

        XCTAssertFalse(result.isPartial)
        XCTAssertTrue(result.shouldFlipOff)
        XCTAssertEqual(result.notConfirmedIssues.map(\.plainReason), ["can't confirm backups"])
    }

    @MainActor
    func testDeleteShareSourceUnreachableDoesNotClearLedger() async throws {
        try await self.assertUnreachablePreservesLedger(
            queue: self.makeQueue(localPortProvider: { nil }),
            handler: { request in
                (Self.response(for: request, statusCode: 200), Self.deleteReceipt(originals: 1))
            }
        )

        try await self.assertUnreachablePreservesLedger(
            queue: self.makeQueue(ensureRegistered: { throw ImportQueueError.registrationUnavailable }),
            handler: { request in
                (Self.response(for: request, statusCode: 200), Self.deleteReceipt(originals: 1))
            }
        )

        try await self.assertUnreachablePreservesLedger(
            queue: self.makeQueue(),
            handler: { _ in throw DeleteSourceTestError.transport }
        )

        try await self.assertUnreachablePreservesLedger(
            queue: self.makeQueue(),
            handler: { request in
                (Self.response(for: request, statusCode: 500), Data("failed".utf8))
            }
        )
    }

    @MainActor
    func testDeleteShareSourceNotConfirmedBodiesDoNotClearLedger() async throws {
        try await self.assertNotConfirmedPreservesLedger(body: Data())
        try await self.assertNotConfirmedPreservesLedger(body: Data("ok".utf8))
    }

    @MainActor
    func testDeleteShareSourcePreservesOtherLedgerStreams() async throws {
        let importID = UUID().uuidString.lowercased()
        let otherID = UUID().uuidString.lowercased()
        let otherEntry = Self.ledgerEntry(stream: "observer.audio")
        try self.writeLedger([
            importID: Self.ledgerEntry(stream: "import.share"),
            otherID: otherEntry,
        ])
        ImportQueueURLProtocol.handler = { request in
            (Self.response(for: request, statusCode: 200), Self.deleteReceipt(originals: 1))
        }
        let queue = self.makeQueue()

        let result = await queue.deleteShareSource()

        XCTAssertTrue(result.shouldFlipOff)
        XCTAssertEqual(try self.readLedger(), [otherID: otherEntry])
    }

    @MainActor
    func testDeleteShareSourceLocalClearFailureReturnsIssue() async throws {
        _ = try self.writeLocalItem(status: "pending")
        ImportQueueURLProtocol.handler = { request in
            (Self.response(for: request, statusCode: 200), Self.deleteReceipt(originals: 1))
        }
        let queue = self.makeQueue(fileManager: RemoveFailingFileManager())

        let result = await queue.deleteShareSource()

        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.notRemovedIssues.contains { $0.what.hasPrefix("pending/") })
    }

    @MainActor
    func testDeleteShareSourceCancelsInFlightUploadAndBlocksLateLedgerWrite() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (Self.response(for: request, statusCode: 200), Self.deleteReceipt(originals: 1))
            }

            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"status":"ok","segment":"120000_0"}"#.utf8)
            )
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))
        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        let result = await queue.deleteShareSource()
        uploadRelease.signal()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(result.shouldFlipOff)
        XCTAssertGreaterThanOrEqual(ImportQueueURLProtocol.cancelledCount, 1)
        XCTAssertNil(try self.readLedger()[itemID])
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
        let deleteConfiguration = URLSessionConfiguration.ephemeral
        deleteConfiguration.protocolClasses = [ImportQueueURLProtocol.self]
        return ImportQueue(
            cacheRootURL: self.tempDirectory,
            fileManager: fileManager,
            sessionConfiguration: configuration,
            deleteSessionConfiguration: deleteConfiguration,
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

    @MainActor
    private func enqueueForPlacement(attributes: [FileAttributeKey: Any], now: Date) async throws -> String {
        let fileManager = AttributeFileManager(attributes: attributes)
        let queue = self.makeQueue(
            fileManager: fileManager,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable },
            now: { now }
        )
        let source = try self.makeSourceFile(named: "\(UUID().uuidString).bin", data: Data("x".utf8))
        return try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "unknown.type"
        ).uuidString.lowercased()
    }

    @MainActor
    private func assertServerSegment(response: String, expected: String) async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        ImportQueueURLProtocol.callCount = 0
        ImportQueueURLProtocol.capturedBodies = []
        ImportQueueURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(response.utf8)
            )
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "source.pdf", data: Data("pdf".utf8))
        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "share-extension",
            stream: "import.share",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("server segment delivery") {
            queue.pendingCount == 0
        }
        let entry = try XCTUnwrap(self.readLedger()[itemID])
        XCTAssertEqual(entry.serverSegment, expected)
        XCTAssertEqual(entry.serverDay.count, 8)
    }

    @MainActor
    private func assertUnreachablePreservesLedger(
        queue: ImportQueue,
        handler: @escaping ImportQueueURLProtocol.Handler
    ) async throws {
        let itemID = UUID().uuidString.lowercased()
        let entry = Self.ledgerEntry(stream: "import.share")
        try self.writeLedger([itemID: entry])
        ImportQueueURLProtocol.handler = handler

        let result = await queue.deleteShareSource()

        guard case .unreachable = result else {
            XCTFail("Expected unreachable result")
            return
        }
        XCTAssertFalse(result.shouldFlipOff)
        XCTAssertEqual(try self.readLedger(), [itemID: entry])
    }

    @MainActor
    private func assertNotConfirmedPreservesLedger(body: Data) async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        let itemID = UUID().uuidString.lowercased()
        let entry = Self.ledgerEntry(stream: "import.share")
        try self.writeLedger([itemID: entry])
        ImportQueueURLProtocol.handler = { request in
            (Self.response(for: request, statusCode: 200), body)
        }
        let queue = self.makeQueue()

        let result = await queue.deleteShareSource()

        XCTAssertEqual(result, .notConfirmed)
        XCTAssertFalse(result.shouldFlipOff)
        XCTAssertEqual(try self.readLedger(), [itemID: entry])
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
        let note = #"{"schema":"solstone.source.item/1","source":"share","origin_app":null,"content_type":"com.adobe.pdf","filename":"source.pdf","bytes":3,"basis":"sent","item_time":"2026-06-02T00:00:00.000Z","target_journal":"home","kind":"raw","item_id":"\#(itemID)"}"#
        try Data(note.utf8).write(to: self.noteURL(itemID: itemID, status: status))
        let request = #"{"day":"20260602","segment":"120000_0","stream":"import.share","filename":"document.pdf","content_type":"application/pdf"}"#
        try Data(request.utf8).write(to: self.descriptorURL(itemID: itemID, status: status))
        return itemID
    }

    private func pendingItemDirectory(itemID: String) -> URL {
        self.tempDirectory
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
    }

    private func failedItemDirectory(itemID: String) -> URL {
        self.tempDirectory
            .appendingPathComponent("failed", isDirectory: true)
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
        self.tempDirectory
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent("raw.bin")
    }

    private func noteURL(itemID: String, status: String) -> URL {
        self.tempDirectory
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent("item.json")
    }

    private func descriptorURL(itemID: String, status: String) -> URL {
        self.tempDirectory
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent("request.json")
    }

    private func readDescriptor(itemID: String) throws -> TestRequestDescriptor {
        try JSONDecoder().decode(TestRequestDescriptor.self, from: Data(contentsOf: self.descriptorURL(itemID: itemID, status: "pending")))
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

    private func noteValue(itemID: String, key: String) throws -> String? {
        let data = try Data(contentsOf: self.noteURL(itemID: itemID, status: "pending"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object[key] as? String
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

    private static func iso8601String(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private static func deleteReceipt(
        originals: Int,
        days: Int? = nil,
        notConfirmed: String? = nil,
        notRemoved: String? = nil
    ) -> Data {
        let daysJSON = days.map { #","days":\#($0)"# } ?? ""
        let notConfirmedJSON = notConfirmed.map { "[\($0)]" } ?? "[]"
        let notRemovedJSON = notRemoved.map { "[\($0)]" } ?? "[]"
        return Data(
            """
            {"target":{"stream":"import.share","journal":"test"},"removed":{"originals":\(originals),"segments":0,"in_segment_derived":0,"index_chunks":0,"stream_identity":0,"history_rows":0\(daysJSON)},"not_confirmed":\(notConfirmedJSON),"not_removed":\(notRemovedJSON),"backup_hosted":"not confirmed"}
            """.utf8
        )
    }

    private static func ledgerEntry(stream: String) -> TestLedgerEntry {
        TestLedgerEntry(
            itemID: UUID().uuidString.lowercased(),
            stream: stream,
            basis: "sent",
            contentType: "com.adobe.pdf",
            targetJournal: "home",
            serverDay: "20260602",
            serverSegment: nil,
            deliveredAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private struct TestRequestDescriptor: Decodable {
    let day: String
    let segment: String
    let stream: String
    let filename: String
    let contentType: String

    enum CodingKeys: String, CodingKey {
        case day
        case segment
        case stream
        case filename
        case contentType = "content_type"
    }
}

private struct TestLedgerEntry: Codable, Equatable {
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

    init(
        itemID: String,
        stream: String,
        basis: String,
        contentType: String,
        targetJournal: String,
        serverDay: String,
        serverSegment: String?,
        deliveredAt: Date,
        filename: String? = nil,
        originApp: String? = nil,
        itemTime: String? = nil
    ) {
        self.itemID = itemID
        self.stream = stream
        self.basis = basis
        self.contentType = contentType
        self.targetJournal = targetJournal
        self.serverDay = serverDay
        self.serverSegment = serverSegment
        self.deliveredAt = deliveredAt
        self.filename = filename
        self.originApp = originApp
        self.itemTime = itemTime
    }

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

private final class NoteWriteFailingFileManager: FileManager, @unchecked Sendable {
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.hasSuffix("item.json") {
            return false
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private final class RemoveFailingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent != "body.upload" {
            throw DeleteSourceTestError.remove
        }
        try super.removeItem(at: URL)
    }
}

private enum DeleteSourceTestError: Error {
    case transport
    case remove
}

private final class AttributeFileManager: FileManager, @unchecked Sendable {
    let attributes: [FileAttributeKey: Any]

    init(attributes: [FileAttributeKey: Any]) {
        self.attributes = attributes
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        self.attributes
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
    private static let cancelledCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
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
    static var cancelledCount: Int {
        get { self.cancelledCountBox.withLock { $0 } }
        set { self.cancelledCountBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
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

    override func stopLoading() {
        Self.cancelledCountBox.withLock { $0 += 1 }
    }

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
