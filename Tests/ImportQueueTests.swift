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
        ImportQueueURLProtocol.handler = { request, body in
            switch request.url?.path {
            case "/app/import/api/save":
                let clientItemID = Self.clientItemID(fromSaveBody: body)
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
        XCTAssertGreaterThan(queue.recentBytesPerSecond, 0)
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
    func testSaveCancelledRequeuesWithoutConsumingAttempt() async throws {
        let shouldCancel = OSAllocatedUnfairLock<Bool>(initialState: true)
        ImportQueueURLProtocol.handler = { request, body in
            switch request.url?.path {
            case "/app/import/api/save":
                if shouldCancel.withLock({ value in
                    if value {
                        value = false
                        return true
                    }
                    return false
                }) {
                    throw URLError(.cancelled)
                }
                let clientItemID = Self.clientItemID(fromSaveBody: body)
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start"}"#.utf8)
                )
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let queue = self.makeQueue(maxAttempts: 1)
        let source = try self.makeSourceFile(named: "cancelled.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("cancelled save completion") {
            ImportQueueURLProtocol.callCount == 2
                && queue.pendingCount == 0
                && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 0)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertNotNil(try self.readLedger()[itemID])
    }

    @MainActor
    func testSaveCancelledReuploadsViaOwnReschedule() async throws {
        // Must RED-FAIL on the bare-`return` build (76237a1) — if it passes without the Sources fix it is masking, not testing.
        let shouldCancel = OSAllocatedUnfairLock<Bool>(initialState: true)
        ImportQueueURLProtocol.handler = { request, body in
            switch request.url?.path {
            case "/app/import/api/save":
                if shouldCancel.withLock({ value in
                    if value {
                        value = false
                        return true
                    }
                    return false
                }) {
                    throw URLError(.cancelled)
                }
                let clientItemID = Self.clientItemID(fromSaveBody: body)
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start"}"#.utf8)
                )
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let queue = self.makeQueue(maxAttempts: 1)
        let source = try self.makeSourceFile(named: "own-reschedule.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("import save cancelled own reschedule") {
            ImportQueueURLProtocol.callCount == 2
                && queue.pendingCount == 0
                && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 0)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertNotNil(try self.readLedger()[itemID])
    }

    @MainActor
    func testStartCancelledUsesFailurePath() async throws {
        let retrySleepGate = ImportQueueRetrySleepGate()
        defer { retrySleepGate.release() }
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"path":"/imports/start-cancelled","timestamp":"2026-04-20T12:00:00Z","recommended_action":"start"}"#.utf8)
            .write(to: self.saveResultURL(itemID: itemID, status: "pending"), options: .atomic)
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/start")
            throw URLError(.cancelled)
        }
        let queue = self.makeQueue(
            retryDelays: [1],
            maxAttempts: 2,
            sleep: { _ in
                await retrySleepGate.sleep()
            }
        )

        await queue.resumeFromDisk()

        try await self.waitFor("start cancellation attempt") {
            queue.attemptCountForTesting(itemID: itemID) == 1
        }
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 1)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/start"])

        retrySleepGate.release()
        try await self.waitFor("start cancellation exhaustion") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 2)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    @MainActor
    func testDropCancelsInFlightSaveUploadAndClearsState() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.heldRequestPredicate = { request in
            request.url?.path == "/app/import/api/save"
        }
        ImportQueueURLProtocol.onHeldRequest = { _ in
            uploadStarted.signal()
        }
        ImportQueueURLProtocol.handler = { request, _ in
            XCTFail("held save upload should not complete normally")
            return (Self.response(for: request, statusCode: 200), Data())
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "drop-save.pdf", data: Data("pdf".utf8))

        let itemUUID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        let itemID = itemUUID.uuidString.lowercased()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        queue.dropItem(itemID: itemUUID)

        try await self.waitFor("save drop cancellation") {
            ImportQueueURLProtocol.stoppedRequests.contains { $0.url?.path == "/app/import/api/save" }
        }
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertNil(queue.lastError)
        XCTAssertNil(try self.readLedgerIfPresent()[itemID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.saveUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.startUploadURL(itemID: itemID, status: "pending").path))
    }

    @MainActor
    func testDropCancelsInFlightStartUploadAndClearsState() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"path":"/imports/drop-start","timestamp":"2026-04-20T12:00:00Z","recommended_action":"start"}"#.utf8)
            .write(to: self.saveResultURL(itemID: itemID, status: "pending"), options: .atomic)
        let itemUUID = try XCTUnwrap(UUID(uuidString: itemID))
        let uploadStarted = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.heldRequestPredicate = { request in
            request.url?.path == "/app/import/api/start"
        }
        ImportQueueURLProtocol.onHeldRequest = { _ in
            uploadStarted.signal()
        }
        ImportQueueURLProtocol.handler = { request, _ in
            XCTFail("held start upload should not complete normally")
            return (Self.response(for: request, statusCode: 200), Data())
        }
        let queue = self.makeQueue(ensureRegistered: {
            XCTFail("start resume should not register")
            throw ImportQueueError.registrationUnavailable
        })

        await queue.resumeFromDisk()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        queue.dropItem(itemID: itemUUID)

        try await self.waitFor("start drop cancellation") {
            ImportQueueURLProtocol.stoppedRequests.contains { $0.url?.path == "/app/import/api/start" }
        }
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertNil(queue.lastError)
        XCTAssertNil(try self.readLedgerIfPresent()[itemID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.saveUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.startUploadURL(itemID: itemID, status: "pending").path))
    }

    @MainActor
    func testDroppedSaveLateFailureIsIgnored() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.respondsAsynchronously = true
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            uploadStarted.signal()
            XCTAssertEqual(uploadRelease.wait(timeout: .now() + 2), .success)
            return (Self.response(for: request, statusCode: 500), Data("late failure".utf8))
        }
        let queue = self.makeQueue(retryDelays: [0])
        let source = try self.makeSourceFile(named: "drop-save-late-failure.pdf", data: Data("pdf".utf8))

        let itemUUID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        let itemID = itemUUID.uuidString.lowercased()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        queue.dropItem(itemID: itemUUID)
        XCTAssertTrue(queue.isDropTombstonedForTesting(itemID: itemID))
        try await self.waitFor("save late failure cancellation") {
            ImportQueueURLProtocol.stoppedRequests.contains { $0.url?.path == "/app/import/api/save" }
        }
        uploadRelease.signal()

        try await self.waitFor("save late failure tombstone eviction") {
            !queue.isDropTombstonedForTesting(itemID: itemID)
        }
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(itemID: itemID, status: "failed").path))
        XCTAssertNil(try self.readLedgerIfPresent()[itemID])
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.saveUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.startUploadURL(itemID: itemID, status: "pending").path))
    }

    @MainActor
    func testDroppedStartLateFailureIsIgnored() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"path":"/imports/drop-start-late-failure","timestamp":"2026-04-20T12:00:00Z","recommended_action":"start"}"#.utf8)
            .write(to: self.saveResultURL(itemID: itemID, status: "pending"), options: .atomic)
        let itemUUID = try XCTUnwrap(UUID(uuidString: itemID))
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.respondsAsynchronously = true
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/start")
            uploadStarted.signal()
            XCTAssertEqual(uploadRelease.wait(timeout: .now() + 2), .success)
            return (Self.response(for: request, statusCode: 500), Data("late failure".utf8))
        }
        let queue = self.makeQueue(ensureRegistered: {
            XCTFail("start resume should not register")
            throw ImportQueueError.registrationUnavailable
        })

        await queue.resumeFromDisk()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        queue.dropItem(itemID: itemUUID)
        XCTAssertTrue(queue.isDropTombstonedForTesting(itemID: itemID))
        try await self.waitFor("start late failure cancellation") {
            ImportQueueURLProtocol.stoppedRequests.contains { $0.url?.path == "/app/import/api/start" }
        }
        uploadRelease.signal()

        try await self.waitFor("start late failure tombstone eviction") {
            !queue.isDropTombstonedForTesting(itemID: itemID)
        }
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(itemID: itemID, status: "failed").path))
        XCTAssertNil(try self.readLedgerIfPresent()[itemID])
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/start"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.saveUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.startUploadURL(itemID: itemID, status: "pending").path))
    }

    @MainActor
    func testDroppedSaveLateSuccessIsSuppressed() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.respondsAsynchronously = true
        ImportQueueURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            uploadStarted.signal()
            XCTAssertEqual(uploadRelease.wait(timeout: .now() + 2), .success)
            return (
                Self.response(for: request, statusCode: 200),
                Self.saveStartResponse(path: "/imports/drop-save-late-success", body: body)
            )
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "drop-save-late-success.pdf", data: Data("pdf".utf8))

        let itemUUID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        let itemID = itemUUID.uuidString.lowercased()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        queue.plantDropTombstoneForTesting(itemID: itemID)
        uploadRelease.signal()

        try await self.waitFor("save late success tombstone eviction") {
            !queue.isDropTombstonedForTesting(itemID: itemID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.saveResultURL(itemID: itemID, status: "pending").path))
        XCTAssertNil(try self.readLedgerIfPresent()[itemID])
        XCTAssertNil(queue.lastDeliveredAt)
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(queue.inFlightCount, 0)
    }

    @MainActor
    func testDroppedStartLateSuccessIsSuppressed() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try Data(#"{"path":"/imports/drop-start-late-success","timestamp":"2026-04-20T12:00:00Z","recommended_action":"start"}"#.utf8)
            .write(to: self.saveResultURL(itemID: itemID, status: "pending"), options: .atomic)
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.respondsAsynchronously = true
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/start")
            uploadStarted.signal()
            XCTAssertEqual(uploadRelease.wait(timeout: .now() + 2), .success)
            return (Self.response(for: request, statusCode: 200), Self.validStartResponse)
        }
        let queue = self.makeQueue(ensureRegistered: {
            XCTFail("start resume should not register")
            throw ImportQueueError.registrationUnavailable
        })

        await queue.resumeFromDisk()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        queue.plantDropTombstoneForTesting(itemID: itemID)
        uploadRelease.signal()

        try await self.waitFor("start late success tombstone eviction") {
            !queue.isDropTombstonedForTesting(itemID: itemID)
        }
        XCTAssertNil(try self.readLedgerIfPresent()[itemID])
        XCTAssertNil(queue.lastDeliveredAt)
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(queue.inFlightCount, 0)
    }

    @MainActor
    func testSaveTransportErrorIncrementsAttemptAndCanExhaust() async throws {
        let retrySleepGate = ImportQueueRetrySleepGate()
        defer { retrySleepGate.release() }
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            throw URLError(.timedOut)
        }
        let queue = self.makeQueue(
            retryDelays: [1],
            maxAttempts: 2,
            sleep: { _ in
                await retrySleepGate.sleep()
            }
        )
        let source = try self.makeSourceFile(named: "timeout.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("save timeout attempt") {
            queue.attemptCountForTesting(itemID: itemID) == 1
        }
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 1)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])

        retrySleepGate.release()
        try await self.waitFor("save timeout exhaustion") {
            queue.failedCount == 1
        }
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 2)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    @MainActor
    func testQuickTextSaveUsesTextFieldWithoutFilePart() async throws {
        ImportQueueURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            let clientItemID = Self.clientItemID(fromSaveBody: body)
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
        ImportQueueURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            let clientItemID = Self.clientItemID(fromSaveBody: body)
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
    func testTerminalDuplicateObjectFinalizesLedgerWithoutStart() async throws {
        ImportQueueURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            let clientItemID = Self.clientItemID(fromSaveBody: body)
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start","path":"/imports/original","timestamp":"2026-04-20T12:00:00Z","duplicate":{"matching_path":"/imports/original","content_hash":"sha256:abc"}}"#.utf8)
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

        try await self.waitFor("terminal duplicate finalizes") {
            queue.pendingCount == 0 && queue.lastDeliveredAt != nil
        }
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, ["/app/import/api/save"])
        let ledgerEntry = try XCTUnwrap(self.readLedger()[itemID])
        XCTAssertEqual(ledgerEntry.serverPath, "/imports/original")
        XCTAssertEqual(ledgerEntry.serverTimestamp, "2026-04-20T12:00:00Z")
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
    }

    @MainActor
    func testSaveResponseMissingClientItemIDFailsWithoutStartOrLedger() async throws {
        ImportQueueURLProtocol.handler = { request, _ in
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
        ImportQueueURLProtocol.handler = { request, _ in
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
            ImportQueueURLProtocol.handler = { request, body in
                XCTAssertEqual(request.url?.path, "/app/import/api/save")
                let clientItemID = Self.clientItemID(fromSaveBody: body)
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
            ImportQueueURLProtocol.handler = { request, body in
                XCTAssertEqual(request.url?.path, "/app/import/api/save")
                let clientItemID = Self.clientItemID(fromSaveBody: body)
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
        ImportQueueURLProtocol.handler = { request, _ in
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
            ImportQueueURLProtocol.handler = { request, _ in
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
    func testStartInvalidOperationForStateFinalizesFromPersistedSaveResultAfterRelaunch() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        try self.writePersistedSaveResult(itemID: itemID, path: "/imports/replayed-start")
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/start")
            return (
                Self.response(for: request, statusCode: 400),
                Data(#"{"reason_code":"invalid_operation_for_state"}"#.utf8)
            )
        }
        let queue = self.makeQueue(maxAttempts: 1)

        await queue.resumeFromDisk()

        try await self.waitFor("invalid operation start replay terminal") {
            queue.pendingCount == 0
        }
        let ledger = try self.readLedgerIfPresent()
        XCTAssertNotNil(ledger[itemID])
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
    }

    @MainActor
    func testStartReplaySafetyOnlyAcceptsInvalidOperationForState400() async throws {
        let cases: [(String, Int, Data)] = [
            ("not-found", 404, Data()),
            ("missing-required-field", 400, Data(#"{"reason_code":"missing_required_field"}"#.utf8)),
        ]

        for (name, statusCode, responseData) in cases {
            ImportQueueURLProtocol.reset()
            let root = self.tempDirectory.appendingPathComponent("start-replay-negative-\(name)", isDirectory: true)
            let itemID = try self.writeLocalItem(root: root, status: "pending")
            try self.writePersistedSaveResult(root: root, itemID: itemID, path: "/imports/\(name)")
            ImportQueueURLProtocol.handler = { request, _ in
                XCTAssertEqual(request.url?.path, "/app/import/api/start")
                return (Self.response(for: request, statusCode: statusCode), responseData)
            }
            let queue = self.makeQueue(cacheRootURL: root, maxAttempts: 1)

            await queue.resumeFromDisk()

            try await self.waitFor("\(name) start replay negative failure") {
                queue.failedCount == 1
            }
            XCTAssertEqual(queue.pendingCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ledger.json").path))
        }
    }

    @MainActor
    func testHTTP409ImportClientIDConflictMovesToFailedWithoutLedgerAndPreservesBody() async throws {
        ImportQueueURLProtocol.handler = { request, _ in
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
        ImportQueueURLProtocol.handler = { request, body in
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
                    Self.saveStartResponse(path: "/imports/retry", body: body)
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
        ImportQueueURLProtocol.handler = { request, _ in
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
    func testFailureRetryClearsInFlightWhenRetryFindsNilPort() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let retrySleepGate = ImportQueueRetrySleepGate()
        let retryParked = OSAllocatedUnfairLock<Bool>(initialState: false)
        defer { retrySleepGate.release() }
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            return (Self.response(for: request, statusCode: 503), Data("service unavailable".utf8))
        }
        let queue = self.makeQueue(
            retryDelays: [1],
            maxAttempts: 3,
            localPortProvider: { localPort.withLock { $0 } },
            sleep: { _ in
                retryParked.withLock { $0 = true }
                await retrySleepGate.sleep()
            }
        )
        let source = try self.makeSourceFile(named: "retry-nil-port.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("failure retry armed") {
            queue.attemptCountForTesting(itemID: itemID) == 1 && queue.inFlightCount == 1
        }
        try await self.waitFor("failure retry parked") {
            retryParked.withLock { $0 }
        }
        localPort.withLock { $0 = nil }
        retrySleepGate.release()

        try await self.waitFor("failure retry in-flight cleared") {
            queue.inFlightCount == 0
        }
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
    }

    @MainActor
    func testReconnectRetryClearsInFlightWhenRetryFindsNilPort() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let retrySleepGate = ImportQueueRetrySleepGate()
        let retryParked = OSAllocatedUnfairLock<Bool>(initialState: false)
        defer { retrySleepGate.release() }
        ImportQueueURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            throw URLError(.cancelled)
        }
        let queue = self.makeQueue(
            retryDelays: [1],
            maxAttempts: 3,
            localPortProvider: { localPort.withLock { $0 } },
            sleep: { _ in
                retryParked.withLock { $0 = true }
                await retrySleepGate.sleep()
            }
        )
        let source = try self.makeSourceFile(named: "reconnect-nil-port.pdf", data: Data("pdf".utf8))

        let itemID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        ).uuidString.lowercased()

        try await self.waitFor("reconnect retry parked") {
            retryParked.withLock { $0 }
        }
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 0)
        localPort.withLock { $0 = nil }
        retrySleepGate.release()

        try await self.waitFor("reconnect retry in-flight cleared") {
            queue.inFlightCount == 0
        }
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.failedCount, 0)
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
        ImportQueueURLProtocol.handler = { request, body in
            switch request.url?.path {
            case "/app/import/api/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Self.saveStartResponse(path: "/imports/item", body: body)
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
    func testResumeReconcilesHeldUploadWhenLocalPortChanges() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let uploadStarted = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.heldRequestPredicate = { request in
            request.url?.path == "/app/import/api/save" && request.url?.port == 7071
        }
        ImportQueueURLProtocol.onHeldRequest = { _ in
            uploadStarted.signal()
        }
        ImportQueueURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            XCTAssertEqual(request.url?.port, 7072)
            let clientItemID = Self.clientItemID(fromSaveBody: body)
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start"}"#.utf8)
            )
        }
        let queue = self.makeQueue(localPortProvider: { localPort.withLock { $0 } })
        let source = try self.makeSourceFile(named: "stale-port.pdf", data: Data("pdf".utf8))

        let itemUUID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        defer { queue.dropItem(itemID: itemUUID) }
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPorts, [7071])

        localPort.withLock { $0 = 7072 }
        await queue.resumeFromDisk()

        try await self.waitFor("stale-port import redispatch") {
            ImportQueueURLProtocol.capturedPorts == [7071, 7072]
                && queue.pendingCount == 0
        }
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(queue.inFlightCount, 0)
    }

    @MainActor
    func testResumeLeavesHeldCurrentPortUploadSingleDispatched() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.heldRequestPredicate = { request in
            request.url?.path == "/app/import/api/save" && request.url?.port == 7071
        }
        ImportQueueURLProtocol.onHeldRequest = { _ in
            uploadStarted.signal()
        }
        ImportQueueURLProtocol.handler = { request, _ in
            XCTFail("held current-port upload should not complete normally: \(request)")
            return (Self.response(for: request, statusCode: 200), Data())
        }
        let queue = self.makeQueue()
        let source = try self.makeSourceFile(named: "current-port.pdf", data: Data("pdf".utf8))

        let itemUUID = try await queue.enqueue(
            fileURL: source,
            source: "document",
            targetJournal: "home",
            contentType: "com.adobe.pdf"
        )
        defer { queue.dropItem(itemID: itemUUID) }
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        await queue.resumeFromDisk()

        XCTAssertEqual(ImportQueueURLProtocol.callCount, 1)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPorts, [7071])
        XCTAssertEqual(queue.inFlightCount, 1)
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
        XCTAssertEqual(Set(ledger.keys), [pendingItemID, failedItemID])
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(try self.directoryEntries(status: "failed"), [])
    }

    @MainActor
    func testConcurrentScheduleCreatesSingleTaskPerItem() async throws {
        let targetItemID = "00000000-0000-0000-0000-000000000030"
        ImportQueueURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            let clientItemID = Self.clientItemID(fromSaveBody: body)
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start"}"#.utf8)
            )
        }
        let gate = ImportQueueRegistrationGate()
        _ = try self.writeLocalItem(status: "pending", itemID: targetItemID)
        let queue = self.makeQueue(ensureRegistered: {
            try await gate.ensureRegistered()
        })

        async let firstResume: Void = queue.resumeFromDisk()
        await gate.waitUntilParked()
        await queue.resumeFromDisk()
        gate.release()
        await firstResume

        try await self.waitFor("single scheduled import") {
            queue.pendingCount == 0
        }
        let saveBodiesForItem = ImportQueueURLProtocol.capturedBodies.filter {
            Self.clientItemID(fromSaveBody: $0) == targetItemID
        }
        XCTAssertEqual(saveBodiesForItem.count, 1)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths.filter { $0 == "/app/import/api/start" }.count, 0)
    }

    @MainActor
    func testDropDuringRegistrationSuccessWindowIsTerminal() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        let itemUUID = try XCTUnwrap(UUID(uuidString: itemID))
        let gate = ImportQueueRegistrationGate()
        let queue = self.makeQueue(ensureRegistered: {
            try await gate.ensureRegistered()
        })

        async let resume: Void = queue.resumeFromDisk()
        await gate.waitUntilParked()
        queue.dropItem(itemID: itemUUID)
        gate.release()
        await resume

        try await self.waitFor("drop during registration success terminal") {
            queue.inFlightCount == 0
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(itemID: itemID, status: "failed").path))
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 0)
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertFalse(queue.isDropTombstonedForTesting(itemID: itemID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.saveUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.startUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, [])
    }

    @MainActor
    func testDropDuringRegistrationThrowWindowIsTerminal() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        let itemUUID = try XCTUnwrap(UUID(uuidString: itemID))
        let gate = ImportQueueRegistrationGate()
        let queue = self.makeQueue(ensureRegistered: {
            try await gate.ensureRegistered()
        })

        async let resume: Void = queue.resumeFromDisk()
        await gate.waitUntilParked()
        queue.dropItem(itemID: itemUUID)
        gate.release(throwing: ImportQueueError.registrationUnavailable)
        await resume

        try await self.waitFor("drop during registration throw terminal") {
            queue.inFlightCount == 0
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(itemID: itemID, status: "failed").path))
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 0)
        XCTAssertNil(queue.lastError)
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertFalse(queue.isDropTombstonedForTesting(itemID: itemID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.saveUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.startUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
        XCTAssertEqual(ImportQueueURLProtocol.capturedPaths, [])
    }

    @MainActor
    func testHeldRegistrationThrowNonDroppedStillFails() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        let gate = ImportQueueRegistrationGate()
        let queue = self.makeQueue(ensureRegistered: {
            try await gate.ensureRegistered()
        })

        async let resume: Void = queue.resumeFromDisk()
        await gate.waitUntilParked()
        gate.release(throwing: ImportQueueError.registrationUnavailable)
        await resume

        try await self.waitFor("held registration throw settled") {
            queue.inFlightCount == 0
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.pendingItemDirectory(itemID: itemID).path))
        XCTAssertEqual(queue.attemptCountForTesting(itemID: itemID), 0)
        XCTAssertNotNil(queue.lastError)
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(ImportQueueURLProtocol.callCount, 0)
    }

    @MainActor
    func testHeldRegistrationSuccessNonDroppedStillUploads() async throws {
        let itemID = try self.writeLocalItem(status: "pending")
        let itemUUID = try XCTUnwrap(UUID(uuidString: itemID))
        let gate = ImportQueueRegistrationGate()
        ImportQueueURLProtocol.heldRequestPredicate = { request in
            request.url?.path == "/app/import/api/save"
        }
        let queue = self.makeQueue(ensureRegistered: {
            try await gate.ensureRegistered()
        })

        async let resume: Void = queue.resumeFromDisk()
        await gate.waitUntilParked()
        gate.release()
        await resume

        try await self.waitFor("held registration success upload started") {
            ImportQueueURLProtocol.callCount >= 1
                && ImportQueueURLProtocol.capturedPaths.contains("/app/import/api/save")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.saveUploadURL(itemID: itemID, status: "pending").path))
        XCTAssertGreaterThanOrEqual(ImportQueueURLProtocol.callCount, 1)
        XCTAssertTrue(ImportQueueURLProtocol.capturedPaths.contains("/app/import/api/save"))

        queue.dropItem(itemID: itemUUID)
        try await self.waitFor("held success upload cleanup") {
            queue.inFlightCount == 0
                && ImportQueueURLProtocol.stoppedRequests.contains { $0.url?.path == "/app/import/api/save" }
        }
    }

    @MainActor
    func testScheduleReservationClearsOnPreTaskExits() async throws {
        let journalRoot = self.tempDirectory.appendingPathComponent("cleanup-journal", isDirectory: true)
        _ = try self.writeLocalItem(root: journalRoot, status: "pending")
        let journalProbe = ImportQueueReservationProbe()
        let journalQueue = self.makeQueue(cacheRootURL: journalRoot, isJournalConfigured: {
            journalProbe.assertReserved()
            return false
        })
        journalProbe.queue = journalQueue

        await journalQueue.resumeFromDisk()
        XCTAssertEqual(journalQueue.inFlightCount, 0)

        let portRoot = self.tempDirectory.appendingPathComponent("cleanup-port", isDirectory: true)
        _ = try self.writeLocalItem(root: portRoot, status: "pending")
        let portProbe = ImportQueueReservationProbe()
        let portQueue = self.makeQueue(cacheRootURL: portRoot, localPortProvider: {
            portProbe.assertReserved()
            return nil
        })
        portProbe.queue = portQueue

        await portQueue.resumeFromDisk()
        XCTAssertEqual(portQueue.inFlightCount, 0)

        let registrationRoot = self.tempDirectory.appendingPathComponent("cleanup-registration", isDirectory: true)
        _ = try self.writeLocalItem(root: registrationRoot, status: "pending")
        let registrationProbe = ImportQueueReservationProbe()
        let registrationQueue = self.makeQueue(cacheRootURL: registrationRoot, ensureRegistered: {
            registrationProbe.assertReserved()
            throw ImportQueueError.registrationUnavailable
        })
        registrationProbe.queue = registrationQueue

        await registrationQueue.resumeFromDisk()
        XCTAssertEqual(registrationQueue.inFlightCount, 0)

        let saveURLRoot = self.tempDirectory.appendingPathComponent("cleanup-save-url", isDirectory: true)
        _ = try self.writeLocalItem(root: saveURLRoot, status: "pending")
        let saveURLProbe = ImportQueueReservationProbe()
        let saveURLQueue = self.makeQueue(
            cacheRootURL: saveURLRoot,
            ensureRegistered: {
                saveURLProbe.assertReserved()
                return "test-observer-key-abc"
            },
            saveURLBuilder: { _ in nil }
        )
        saveURLProbe.queue = saveURLQueue

        await saveURLQueue.resumeFromDisk()
        XCTAssertEqual(saveURLQueue.inFlightCount, 0)

        let startURLRoot = self.tempDirectory.appendingPathComponent("cleanup-start-url", isDirectory: true)
        let startItemID = try self.writeLocalItem(root: startURLRoot, status: "pending")
        let startSaveResultURL = startURLRoot
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(startItemID, isDirectory: true)
            .appendingPathComponent("save.json")
        try Data(#"{"path":"/imports/start","timestamp":"2026-04-20T12:00:00Z","recommended_action":"start"}"#.utf8)
            .write(to: startSaveResultURL, options: .atomic)
        let startURLProbe = ImportQueueReservationProbe()
        let startURLQueue = self.makeQueue(
            cacheRootURL: startURLRoot,
            isJournalConfigured: {
                startURLProbe.assertReserved()
                return true
            },
            startURLBuilder: { _ in nil }
        )
        startURLProbe.queue = startURLQueue

        await startURLQueue.resumeFromDisk()
        XCTAssertEqual(startURLQueue.inFlightCount, 0)

        let bodyRoot = self.tempDirectory.appendingPathComponent("cleanup-body", isDirectory: true)
        _ = try self.writeLocalItem(
            root: bodyRoot,
            status: "pending",
            rawData: Data([0xff, 0xfe, 0xfd]),
            source: "quick",
            noteContentType: "public.plain-text",
            noteFilename: "note.txt",
            descriptorFilename: "text.txt",
            descriptorContentType: "text/plain"
        )
        let bodyProbe = ImportQueueReservationProbe()
        let bodyQueue = self.makeQueue(cacheRootURL: bodyRoot, maxAttempts: 1, ensureRegistered: {
            bodyProbe.assertReserved()
            return "test-observer-key-abc"
        })
        bodyProbe.queue = bodyQueue

        await bodyQueue.resumeFromDisk()
        XCTAssertEqual(bodyQueue.inFlightCount, 0)

        // Missing required files are prefiltered by resumeFromDisk with requiredFilesExist before scheduleUpload is called.
    }

    func testConcurrentSaveResponsesEchoEachRequestClientItemID() async throws {
        let arrivalOrder = OSAllocatedUnfairLock<[String]>(initialState: [])
        let responseOrder = OSAllocatedUnfairLock<[String]>(initialState: [])
        let alphaArrived = DispatchSemaphore(value: 0)
        let bothArrived = DispatchSemaphore(value: 0)
        let betaResponseBuilt = DispatchSemaphore(value: 0)
        ImportQueueURLProtocol.respondsAsynchronously = true
        ImportQueueURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/app/import/api/save")
            let clientItemID = Self.clientItemID(fromSaveBody: body)
            let arrivalCount = arrivalOrder.withLock { order in
                order.append(clientItemID)
                return order.count
            }
            if clientItemID == "alpha" {
                alphaArrived.signal()
            }
            if arrivalCount == 2 {
                bothArrived.signal()
                bothArrived.signal()
            }
            XCTAssertEqual(bothArrived.wait(timeout: .now() + .seconds(5)), .success)
            if clientItemID == "alpha" {
                XCTAssertEqual(betaResponseBuilt.wait(timeout: .now() + .seconds(5)), .success)
            }
            let response = (
                Self.response(for: request, statusCode: 200),
                Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"do_not_start"}"#.utf8)
            )
            responseOrder.withLock { $0.append(clientItemID) }
            if clientItemID == "beta" {
                betaResponseBuilt.signal()
            }
            return response
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportQueueURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 2
        let alphaSession = URLSession(configuration: configuration)
        let betaSession = URLSession(configuration: configuration)
        defer {
            alphaSession.invalidateAndCancel()
            betaSession.invalidateAndCancel()
        }

        async let alphaClientItemID = Self.uploadSaveClientItemID("alpha", session: alphaSession)
        let alphaArrival = await withCheckedContinuation { (continuation: CheckedContinuation<DispatchTimeoutResult, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: alphaArrived.wait(timeout: .now() + .seconds(5)))
            }
        }
        guard alphaArrival == .success else {
            XCTFail("alpha /save request did not arrive")
            return
        }
        async let betaClientItemID = Self.uploadSaveClientItemID("beta", session: betaSession)

        let (alpha, beta) = try await (alphaClientItemID, betaClientItemID)
        XCTAssertEqual(arrivalOrder.withLock { $0 }, ["alpha", "beta"])
        XCTAssertEqual(responseOrder.withLock { $0 }, ["beta", "alpha"])
        XCTAssertEqual(beta, "beta")
        XCTAssertEqual(alpha, "alpha")
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
        saveURLBuilder: @escaping @Sendable (Int) -> URL? = { ImporterServerURL.saveURL(localPort: $0) },
        startURLBuilder: @escaping @Sendable (Int) -> URL? = { ImporterServerURL.startURL(localPort: $0) },
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
            saveURLBuilder: saveURLBuilder,
            startURLBuilder: startURLBuilder,
            retryDelays: retryDelays,
            maxAttempts: maxAttempts,
            sleep: sleep,
            startPathMonitor: false,
            now: now
        )
    }

    private func installSuccessfulImportHandler() {
        ImportQueueURLProtocol.handler = { request, body in
            switch request.url?.path {
            case "/app/import/api/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Self.saveStartResponse(path: "/imports/retry", body: body)
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
        itemID: String = UUID().uuidString.lowercased(),
        rawData: Data = Data("raw".utf8),
        source: String = "document",
        noteContentType: String = "com.adobe.pdf",
        noteFilename: String = "source.pdf",
        descriptorFilename: String = "document.pdf",
        descriptorContentType: String = "application/pdf"
    ) throws -> String {
        let root = root ?? self.tempDirectory!
        let directory = root
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rawData.write(to: directory.appendingPathComponent("raw.bin"))
        let note = #"{"schema":"solstone.source.item/1","source":"\#(source)","origin_app":null,"content_type":"\#(noteContentType)","filename":"\#(noteFilename)","bytes":\#(rawData.count),"basis":"sent","item_time":"2026-06-02T00:00:00.000Z","target_journal":"home","kind":"raw","item_id":"\#(itemID)"}"#
        try Data(note.utf8).write(to: directory.appendingPathComponent("item.json"))
        let request = #"{"source":"\#(source)","filename":"\#(descriptorFilename)","content_type":"\#(descriptorContentType)"}"#
        try Data(request.utf8).write(to: directory.appendingPathComponent("request.json"))
        return itemID
    }

    private func writePersistedSaveResult(
        root: URL? = nil,
        itemID: String,
        status: String = "pending",
        path: String,
        timestamp: String = "2026-04-20T12:00:00Z",
        recommendedAction: String = "start"
    ) throws {
        let root = root ?? self.tempDirectory!
        let url = root
            .appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent("save.json")
        let body = #"{"path":"\#(path)","timestamp":"\#(timestamp)","recommended_action":"\#(recommendedAction)"}"#
        try Data(body.utf8).write(to: url, options: .atomic)
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

    private func saveUploadURL(itemID: String, status: String) -> URL {
        self.itemDirectory(itemID: itemID, status: status).appendingPathComponent("save.upload")
    }

    private func startUploadURL(itemID: String, status: String) -> URL {
        self.itemDirectory(itemID: itemID, status: status).appendingPathComponent("start.upload")
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

    private func readLedgerIfPresent() throws -> [String: TestLedgerEntry] {
        guard self.ledgerExists() else { return [:] }
        return try self.readLedger()
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

    private static func uploadSaveClientItemID(_ clientItemID: String, session: URLSession) async throws -> String {
        let boundary = "Boundary-\(clientItemID)"
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:7071/app/import/api/save")))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"client_item_id\"\r\n\r\n\(clientItemID)\r\n--\(boundary)--\r\n".utf8
        )
        let (data, _) = try await session.upload(for: request, from: body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        return try XCTUnwrap(json["client_item_id"])
    }

    private static func saveStartResponse(path: String, body: Data, timestamp: String = "2026-04-20T12:00:00Z") -> Data {
        let clientItemID = self.clientItemID(fromSaveBody: body)
        return Data(#"{"client_item_id":"\#(clientItemID)","recommended_action":"start","path":"\#(path)","timestamp":"\#(timestamp)"}"#.utf8)
    }

    private static func clientItemID(fromSaveBody data: Data) -> String {
        guard let string = String(data: data, encoding: .utf8),
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

@MainActor
private final class ImportQueueRegistrationGate {
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<String, any Error>?
    private var isParked = false
    private var releasedResult: Result<String, any Error>?

    func ensureRegistered() async throws -> String {
        guard !self.isParked else {
            return try self.releasedResult?.get() ?? "test-observer-key-abc"
        }
        self.isParked = true
        self.parkedContinuation?.resume()
        self.parkedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.releaseContinuation = continuation
        }
    }

    func waitUntilParked() async {
        guard !self.isParked else { return }
        await withCheckedContinuation { continuation in
            self.parkedContinuation = continuation
        }
    }

    func release(handle: String = "test-observer-key-abc") {
        self.releasedResult = .success(handle)
        self.releaseContinuation?.resume(returning: handle)
        self.releaseContinuation = nil
    }

    func release(throwing error: any Error) {
        self.releasedResult = .failure(error)
        self.releaseContinuation?.resume(throwing: error)
        self.releaseContinuation = nil
    }
}

@MainActor
private final class ImportQueueReservationProbe {
    weak var queue: ImportQueue?

    func assertReserved(file: StaticString = #filePath, line: UInt = #line) {
        guard let queue else {
            XCTFail("ImportQueue reservation probe missing queue", file: file, line: line)
            return
        }
        XCTAssertEqual(queue.inFlightCount, 1, file: file, line: line)
    }
}

private final class ImportQueueRetrySleepGate: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var released = false
    }

    private let lock = NSLock()
    private var state = State()

    func sleep() async {
        await withCheckedContinuation { continuation in
            let shouldResume = self.lock.withLock {
                if self.state.released {
                    return true
                }
                self.state.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuation = self.lock.withLock {
            self.state.released = true
            let continuation = self.state.continuation
            self.state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class ImportQueueURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)
    typealias RequestPredicate = @Sendable (URLRequest) -> Bool
    typealias RequestObserver = @Sendable (URLRequest) -> Void

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let heldRequestPredicateBox = OSAllocatedUnfairLock<RequestPredicate?>(initialState: nil)
    private static let onHeldRequestBox = OSAllocatedUnfairLock<RequestObserver?>(initialState: nil)
    private static let respondsAsynchronouslyBox = OSAllocatedUnfairLock<Bool>(initialState: false)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private static let pathsBox = OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let portsBox = OSAllocatedUnfairLock<[Int?]>(initialState: [])
    private static let stoppedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }
    static var heldRequestPredicate: RequestPredicate? {
        get { self.heldRequestPredicateBox.withLock { $0 } }
        set { self.heldRequestPredicateBox.withLock { $0 = newValue } }
    }
    static var onHeldRequest: RequestObserver? {
        get { self.onHeldRequestBox.withLock { $0 } }
        set { self.onHeldRequestBox.withLock { $0 = newValue } }
    }
    static var respondsAsynchronously: Bool {
        get { self.respondsAsynchronouslyBox.withLock { $0 } }
        set { self.respondsAsynchronouslyBox.withLock { $0 = newValue } }
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
    static var capturedPorts: [Int?] {
        get { self.portsBox.withLock { $0 } }
        set { self.portsBox.withLock { $0 = newValue } }
    }
    static var stoppedRequests: [URLRequest] {
        get { self.stoppedRequestsBox.withLock { $0 } }
        set { self.stoppedRequestsBox.withLock { $0 = newValue } }
    }

    static func reset() {
        self.handler = nil
        self.heldRequestPredicate = nil
        self.onHeldRequest = nil
        self.respondsAsynchronously = false
        self.callCount = 0
        self.capturedBodies = []
        self.capturedPaths = []
        self.capturedPorts = []
        self.stoppedRequests = []
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
        Self.portsBox.withLock { $0.append(self.request.url?.port) }
        let body = Self.bodyData(from: self.request)
        Self.bodiesBox.withLock { $0.append(body) }
        if Self.heldRequestPredicate?(self.request) == true {
            Self.onHeldRequest?(self.request)
            return
        }
        guard let handler = Self.handler else {
            XCTFail("ImportQueueURLProtocol handler not set")
            return
        }

        let request = self.request
        if Self.respondsAsynchronously {
            DispatchQueue.global().async {
                self.load(handler: handler, request: request, body: body)
            }
        } else {
            self.load(handler: handler, request: request, body: body)
        }
    }

    override func stopLoading() {
        Self.stoppedRequestsBox.withLock { $0.append(self.request) }
    }

    private func load(handler: Handler, request: URLRequest, body: Data) {
        do {
            let (response, data) = try handler(request, body)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var output = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            output.append(buffer, count: read)
        }
        return output
    }
}
