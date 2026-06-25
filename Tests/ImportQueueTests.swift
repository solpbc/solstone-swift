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
                let clientItemID = Self.clientItemID(fromLatestSaveBody: ImportQueueURLProtocol.capturedBodies.last)
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"start","path":"/imports/item-1","timestamp":"2026-04-20T12:00:00Z","source":"audio"}"#.utf8)
                )
            case "/app/import/api/start":
                return (
                    Self.response(for: request, statusCode: 200),
                    Self.validStartResponse
                )
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "memo.m4a", data: Data("audio".utf8))
        let completionCounter = ImportQueueCompletionCounter()
        queue.handleBackgroundURLSessionEvents {
            completionCounter.increment()
        }

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "audio",
            targetJournal: "home",
            contentType: "public.m4a-audio",
            originalFilename: "memo.m4a",
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
        XCTAssertTrue(saveBody.contains(#"name="client_item_id""#))
        XCTAssertTrue(saveBody.contains(itemID))
        XCTAssertTrue(saveBody.contains(#"name="file"; filename="audio.m4a""#))
        XCTAssertTrue(saveBody.contains("Content-Type: audio/mp4"))
        XCTAssertFalse(saveBody.contains(#"name="source""#))
        XCTAssertFalse(saveBody.contains(#"name="day""#))
        XCTAssertFalse(saveBody.contains(#"name="segment""#))
        XCTAssertFalse(saveBody.contains(#"name="platform""#))
        XCTAssertFalse(saveBody.contains("item.json"))

        let startBody = try XCTUnwrap(JSONSerialization.jsonObject(with: ImportQueueURLProtocol.capturedBodies[1]) as? [String: Any])
        XCTAssertEqual(startBody["path"] as? String, "/imports/item-1")
        XCTAssertEqual(startBody["timestamp"] as? String, "2026-04-20T12:00:00Z")
        XCTAssertNil(startBody["source"])
        XCTAssertEqual(Set(startBody.keys), Set(["path", "timestamp"]))

        let ledger = try self.readLedger()
        XCTAssertEqual(ledger[itemID]?.serverPath, "/imports/item-1")
        XCTAssertEqual(ledger[itemID]?.serverTimestamp, "2026-04-20T12:00:00Z")
        XCTAssertEqual(ledger[itemID]?.filename, "memo.m4a")
        XCTAssertEqual(ledger[itemID]?.originApp, "com.example.files")
        XCTAssertNotNil(ledger[itemID]?.itemTime)

        queue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testQuickTextSaveUsesTextFieldWithoutFilePart() async throws {
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            let clientItemID = Self.clientItemID(fromLatestSaveBody: ImportQueueURLProtocol.capturedBodies.last)
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start","path":"/imports/text","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)
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

        try await self.waitFor("text delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        let body = String(decoding: try XCTUnwrap(ImportQueueURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="text""#))
        XCTAssertTrue(body.contains("  hello text  "))
        XCTAssertFalse(body.contains(#"name="file""#))
        XCTAssertTrue(body.contains(#"name="client_item_id""#))
        let ledger = try self.readLedger()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.values.first?.serverPath, "/imports/text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: try XCTUnwrap(ledger.keys.first)).path))
    }

    @MainActor
    func testDoNotStartWithoutPathTimestampFinalizesLedgerWithNilServerFields() async throws {
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            let clientItemID = Self.clientItemID(fromLatestSaveBody: ImportQueueURLProtocol.capturedBodies.last)
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start"}"#.utf8)
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

        try await self.waitFor("do not start delivery") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
        let ledgerEntry = try XCTUnwrap(self.readLedger()[itemID])
        XCTAssertNil(ledgerEntry.serverPath)
        XCTAssertNil(ledgerEntry.serverTimestamp)
    }

    @MainActor
    func testSaveResponseMissingClientItemIDFailsWithoutStartOrLedger() async throws {
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"recommended_action":"start","path":"/imports/missing-client","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)
            )
        }
        let queue = self.makeQueue(maxAttempts: 1)
        let source = try self.makeSourceFile(named: "missing-client.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("missing client id failure") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        XCTAssertFalse(self.ledgerExists())
    }

    @MainActor
    func testSaveResponseClientItemIDMismatchFailsWithoutStartOrLedger() async throws {
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"client_item_id":"wrong-client","recommended_action":"start","path":"/imports/mismatch","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)
            )
        }
        let queue = self.makeQueue(maxAttempts: 1)
        let source = try self.makeSourceFile(named: "mismatch.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("client id mismatch failure") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        XCTAssertFalse(self.ledgerExists())
        XCTAssertNotNil(queue.lastError)
    }

    @MainActor
    func testSaveResponseUnknownRecommendedActionFailsWithoutStartOrLedger() async throws {
        let cases: [(String, String)] = [
            ("missing", #"{"client_item_id":"CLIENT","path":"/imports/missing-action","timestamp":"2026-04-20T12:00:00Z"}"#),
            ("unknown", #"{"client_item_id":"CLIENT","recommended_action":"later","path":"/imports/unknown-action","timestamp":"2026-04-20T12:00:00Z"}"#),
        ]

        for (name, template) in cases {
            ImportQueueURLProtocol.reset()
            let root = self.tempDirectory.appendingPathComponent("recommended-action-\(name)", isDirectory: true)
            ImportQueueURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/app/import/api/save")
                let clientItemID = Self.clientItemID(fromLatestSaveBody: ImportQueueURLProtocol.capturedBodies.last)
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(template.replacingOccurrences(of: "CLIENT", with: clientItemID).utf8)
                )
            }
            let queue = self.makeQueue(cacheRootURL: root, maxAttempts: 1)
            let source = try self.makeSourceFile(named: "\(name).pdf", data: Data("pdf".utf8))

            _ = try await queue.enqueue(
                fileURL: source,
                source: "document",
                targetJournal: "home",
                contentType: "com.adobe.pdf"
            )

            try await self.waitFor("\(name) recommended action failure") {
                queue.failedCount == 1
            }
            XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ledger.json").path))
        }
    }

    @MainActor
    func testStartActionRequiresPathAndTimestampBeforePersistingSaveResult() async throws {
        let cases: [(String, String)] = [
            ("missing-path", #"{"client_item_id":"CLIENT","recommended_action":"start","timestamp":"2026-04-20T12:00:00Z"}"#),
            ("missing-timestamp", #"{"client_item_id":"CLIENT","recommended_action":"start","path":"/imports/missing-timestamp"}"#),
        ]

        for (name, template) in cases {
            ImportQueueURLProtocol.reset()
            let root = self.tempDirectory.appendingPathComponent(name, isDirectory: true)
            ImportQueueURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/app/import/api/save")
                let clientItemID = Self.clientItemID(fromLatestSaveBody: ImportQueueURLProtocol.capturedBodies.last)
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(template.replacingOccurrences(of: "CLIENT", with: clientItemID).utf8)
                )
            }
            let queue = self.makeQueue(cacheRootURL: root, maxAttempts: 1)
            let source = try self.makeSourceFile(named: "\(name).pdf", data: Data("pdf".utf8))

            let itemID = try await queue.enqueue(
                fileURL: source,
                source: "document",
                targetJournal: "home",
                contentType: "com.adobe.pdf"
            ).uuidString.lowercased()

            try await self.waitFor("\(name) missing start field failure") {
                queue.failedCount == 1
            }
            XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
            let saveResultURL = root
                .appendingPathComponent("pending", isDirectory: true)
                .appendingPathComponent(itemID, isDirectory: true)
                .appendingPathComponent("save.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: saveResultURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ledger.json").path))
        }
    }

    @MainActor
    func testPersistedSaveResultResumesAtStartWithoutRegistrationOrResave() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"path":"/imports/saved","timestamp":"2026-04-20T12:00:00Z","recommended_action":"start"}"#.utf8)
            .write(to: self.saveResultURL(itemID: itemID, status: "pending"), options: .atomic)
        let registrationCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/start")
            return (Self.response(for: request, statusCode: 200), Self.validStartResponse)
        }
        let queue = self.makeQueue(ensureRegistered: {
            registrationCalls.withLock { $0 += 1 }
            throw ImportQueueError.registrationUnavailable
        })

        await queue.resumeFromDisk()

        try await self.waitFor("saved item start") {
            queue.pendingCount == 0 && ImportQueueURLProtocol.callCount == 1
        }
        XCTAssertEqual(registrationCalls.withLock { $0 }, 0)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/start"])
        let startBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ImportQueueURLProtocol.capturedBodies.first)) as? [String: Any])
        XCTAssertEqual(startBody["path"] as? String, "/imports/saved")
        XCTAssertEqual(startBody["timestamp"] as? String, "2026-04-20T12:00:00Z")
        XCTAssertNil(startBody["source"])
        XCTAssertEqual(try self.readLedger()[itemID]?.serverPath, "/imports/saved")
    }

    @MainActor
    func testPersistedNonStartableSaveResultFailsWithoutResaveOrStart() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"path":"/imports/not-startable","timestamp":"2026-04-20T12:00:00Z","recommended_action":"do_not_start"}"#.utf8)
            .write(to: self.saveResultURL(itemID: itemID, status: "pending"), options: .atomic)
        let queue = self.makeQueue(maxAttempts: 1)

        await queue.resumeFromDisk()

        try await self.waitFor("non-startable save result failure") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
        XCTAssertFalse(self.ledgerExists())
    }

    @MainActor
    func testStartResponseMustBeOkWithNonEmptyTaskIDBeforeFinalizing() async throws {
        let cases: [(String, Data)] = [
            ("non-ok", Data(#"{"status":"queued","task_id":"task-1"}"#.utf8)),
            ("missing-task", Data(#"{"status":"ok"}"#.utf8)),
            ("empty-task", Data(#"{"status":"ok","task_id":""}"#.utf8)),
            ("malformed", Data("not json".utf8)),
        ]

        for (name, responseData) in cases {
            ImportQueueURLProtocol.reset()
            let root = self.tempDirectory.appendingPathComponent("start-response-\(name)", isDirectory: true)
            let itemID = try self.writeLocalItem(root: root, status: "pending")
            try Data(#"{"path":"/imports/\#(name)","timestamp":"2026-04-20T12:00:00Z","recommended_action":"start"}"#.utf8)
                .write(to: root
                    .appendingPathComponent("pending", isDirectory: true)
                    .appendingPathComponent(itemID, isDirectory: true)
                    .appendingPathComponent("save.json"), options: .atomic)
            ImportQueueURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/app/import/api/start")
                return (Self.response(for: request, statusCode: 200), responseData)
            }
            let queue = self.makeQueue(cacheRootURL: root, maxAttempts: 1)

            await queue.resumeFromDisk()

            try await self.waitFor("\(name) start response failure") {
                queue.failedCount == 1
            }
            XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/start"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ledger.json").path))
        }
    }

    @MainActor
    func testHTTP409ImportClientIDConflictMovesToFailedWithoutLedgerAndPreservesBody() async throws {
        ImportQueueURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            return (
                Self.response(for: request, statusCode: 409),
                Data(#"{"error":"import_client_id_conflict","detail":"client id belongs to another import"}"#.utf8)
            )
        }
        let queue = self.makeQueue(maxAttempts: 1)
        let source = try self.makeSourceFile(named: "conflict.pdf", data: Data("pdf".utf8))

        _ = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )

        try await self.waitFor("409 conflict failure") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        XCTAssertFalse(self.ledgerExists())
        XCTAssertTrue((queue.lastError ?? "").contains("HTTP 409"))
        XCTAssertTrue((queue.lastError ?? "").contains("import_client_id_conflict"))
    }

    @MainActor
    func testAudioContentTypesInferAudioFilenameAndMIMEViaEnqueue() async throws {
        let queue = self.makeQueue(isJournalConfigured: { false })
        let cases: [(String, String, String, String)] = [
            ("public.mp3", "audio", "audio.mp3", "audio/mpeg"),
            ("public.m4a-audio", "audio", "audio.m4a", "audio/mp4"),
            ("com.unknown.bogus", "document", "item.bin", "application/octet-stream"),
        ]

        for (contentType, importSource, expectedFilename, expectedContentType) in cases {
            let source = try self.makeSourceFile(named: "\(UUID().uuidString).bin", data: Data("data".utf8))
            let itemID = try await queue.enqueue(
                fileURL: source,
                source: importSource,
                targetJournal: "home",
                contentType: contentType
            ).uuidString.lowercased()
            let descriptor = try self.readDescriptor(itemID: itemID)
            XCTAssertEqual(descriptor.filename, expectedFilename)
            XCTAssertEqual(descriptor.contentType, expectedContentType)
        }
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
                    Self.saveStartResponse(path: "/imports/retry")
                )
            case "/app/import/api/start":
                if startFailures.withLock({ count in
                    count += 1
                    return count
                }) <= 4 {
                    return (Self.response(for: request, statusCode: 503), Data("start unavailable".utf8))
                }
                return (Self.response(for: request, statusCode: 200), Self.validStartResponse)
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
                    Self.saveStartResponse(path: "/imports/item")
                )
            case "/app/import/api/start":
                return (Self.response(for: request, statusCode: 200), Self.validStartResponse)
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
    func testRetryFailedMovesFailedItemsToPendingAndUploads() async throws {
        self.installSuccessfulImportHandler()
        let itemIDs = try [
            self.writeLocalItem(status: "failed", itemID: "00000000-0000-0000-0000-000000000001"),
            self.writeLocalItem(status: "failed", itemID: "00000000-0000-0000-0000-000000000002"),
            self.writeLocalItem(status: "failed", itemID: "00000000-0000-0000-0000-000000000003"),
        ]
        let queue = self.makeQueue()
        XCTAssertEqual(queue.failedCount, itemIDs.count)

        await queue.retryFailed()

        try await self.waitFor("retry failed imports") {
            queue.pendingCount == 0
                && queue.failedCount == 0
                && ImportQueueURLProtocol.callCount == itemIDs.count * 2
        }
        XCTAssertEqual(try self.directoryEntries(status: "failed"), [])
        let ledger = try self.readLedger()
        for itemID in itemIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
            XCTAssertNotNil(ledger[itemID])
        }
    }

    @MainActor
    func testRetryFailedSkipsInvalidAndIncompleteFailedItemsWithoutAborting() async throws {
        self.installSuccessfulImportHandler()
        let validItemID = try self.writeLocalItem(status: "failed", itemID: "00000000-0000-0000-0000-000000000010")
        let invalidDirectory = self.tempDirectory
            .appendingPathComponent("failed", isDirectory: true)
            .appendingPathComponent("not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let incompleteItemID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let incompleteDirectory = self.itemDirectory(itemID: incompleteItemID, status: "failed")
        try FileManager.default.createDirectory(at: incompleteDirectory, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: self.rawURL(itemID: incompleteItemID, status: "failed"))
        try Data("{}".utf8).write(to: self.noteURL(itemID: incompleteItemID, status: "failed"))
        let queue = self.makeQueue()
        XCTAssertEqual(queue.failedCount, 3)

        await queue.retryFailed()
        XCTAssertNotNil(queue.lastError)

        try await self.waitFor("valid retry did not abort") {
            ImportQueueURLProtocol.callCount == 2
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(itemID: validItemID, status: "failed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: validItemID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incompleteDirectory.path))
        XCTAssertEqual(queue.failedCount, 2)
    }

    @MainActor
    func testRetryFailedConcurrentWithResumeSchedulesEachItemAtMostOnce() async throws {
        self.installSuccessfulImportHandler()
        let pendingItemID = try self.writeLocalItem(status: "pending", itemID: "00000000-0000-0000-0000-000000000020")
        let failedItemID = try self.writeLocalItem(status: "failed", itemID: "00000000-0000-0000-0000-000000000021")
        let queue = self.makeQueue()

        async let retry: Void = queue.retryFailed()
        async let resume: Void = queue.resumeFromDisk()
        _ = await (retry, resume)

        try await self.waitFor("concurrent retry and resume") {
            queue.pendingCount == 0
                && queue.failedCount == 0
                && ImportQueueURLProtocol.callCount == 4
        }
        let ledger = try self.readLedger()
        XCTAssertNotNil(ledger[pendingItemID])
        XCTAssertNotNil(ledger[failedItemID])
        XCTAssertEqual(try self.directoryEntries(status: "failed"), [])
    }

    @MainActor
    private func makeQueue(
        cacheRootURL: URL? = nil,
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
            cacheRootURL: cacheRootURL ?? self.tempDirectory,
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

    private func installSuccessfulImportHandler() {
        ImportQueueURLProtocol.handler = { request in
            switch request.url?.path {
            case "/app/import/api/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Self.saveStartResponse(path: "/imports/retry")
                )
            case "/app/import/api/start":
                return (Self.response(for: request, statusCode: 200), Self.validStartResponse)
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
    }

    private func makeSourceFile(named name: String, data: Data) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeLocalItem(
        root: URL? = nil,
        status: String,
        itemID: String = UUID().uuidString.lowercased()
    ) throws -> String {
        let root = root ?? self.tempDirectory!
        let directory = root
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: directory.appendingPathComponent("raw.bin"))
        let note = #"{"schema":"solstone.source.item/1","source":"document","origin_app":null,"content_type":"com.adobe.pdf","filename":"source.pdf","bytes":3,"basis":"sent","item_time":"2026-06-02T00:00:00.000Z","target_journal":"home","kind":"raw","item_id":"\#(itemID)"}"#
        try Data(note.utf8).write(to: directory.appendingPathComponent("item.json"))
        let request = #"{"source":"document","filename":"document.pdf","content_type":"application/pdf"}"#
        try Data(request.utf8).write(to: directory.appendingPathComponent("request.json"))
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

    private func ledgerExists() -> Bool {
        FileManager.default.fileExists(atPath: self.tempDirectory.appendingPathComponent("ledger.json").path)
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

    private static let validStartResponse = Data(#"{"status":"ok","task_id":"task-1"}"#.utf8)

    private static func saveStartResponse(path: String, timestamp: String = "2026-04-20T12:00:00Z") -> Data {
        let clientItemID = self.clientItemID(fromLatestSaveBody: ImportQueueURLProtocol.capturedBodies.last)
        return Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"start","path":"\#(path)","timestamp":"\#(timestamp)"}"#.utf8)
    }

    private static func clientItemID(fromLatestSaveBody data: Data?) -> String {
        guard let data,
              let string = String(data: data, encoding: .utf8),
              let markerRange = string.range(of: "name=\"client_item_id\"\r\n\r\n")
        else {
            return "MISSING"
        }
        let rest = string[markerRange.upperBound...]
        guard let end = rest.range(of: "\r\n") else { return "MISSING" }
        return String(rest[..<end.lowerBound])
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
