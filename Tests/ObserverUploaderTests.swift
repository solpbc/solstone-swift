// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ObserverUploaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverUploaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        ObserverUploaderURLProtocol.handler = nil
        ObserverUploaderURLProtocol.callCount = 0
        ObserverUploaderURLProtocol.capturedBodies = []
        ObserverUploaderURLProtocol.capturedRequests = []
        ObserverUploaderURLProtocol.stoppedRequests = []
        ObserverUploaderURLProtocol.heldRequestPredicate = nil
        ObserverUploaderURLProtocol.onHeldRequest = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        ObserverUploaderURLProtocol.handler = nil
        ObserverUploaderURLProtocol.callCount = 0
        ObserverUploaderURLProtocol.capturedBodies = []
        ObserverUploaderURLProtocol.capturedRequests = []
        ObserverUploaderURLProtocol.stoppedRequests = []
        ObserverUploaderURLProtocol.heldRequestPredicate = nil
        ObserverUploaderURLProtocol.onHeldRequest = nil
        super.tearDown()
    }

    @MainActor
    func testEnqueueUploadsAndCleansPendingFiles() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/app/observer/ingest")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        let uploader = self.makeUploader()
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-1")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("upload cleanup") {
            uploader.pendingCount == 0 && uploader.lastUploadAt != nil
        }

        XCTAssertGreaterThan(uploader.recentBytesPerSecond, 0)
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingAudioURL(sessionID: sessionID, chunkID: "chunk-1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingSidecarURL(sessionID: sessionID, chunkID: "chunk-1").path))
    }

    // ImportQueue and LocationUploader intentionally stay off the audio .m4a delta seam: they count directories and .jsonl files with batch clears/origin-less drops.
    @MainActor
    func testSuccessfulCompletionsUseDeltasWithoutFullRecountsScalingWithCompletions() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        let uploader = self.makeUploader()
        let baselineRecounts = uploader.fullRecountCount
        let sessionID = UUID()

        for index in 0..<5 {
            let sourceURL = try self.makeChunkFile(named: "chunk-delta-\(index)")
            await uploader.enqueue(
                chunkURL: sourceURL,
                sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: index)
            )
        }

        try await self.waitFor("delta upload cleanup") {
            ObserverUploaderURLProtocol.callCount == 5 && uploader.pendingCount == 0 && uploader.lastUploadAt != nil
        }
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(uploader.fullRecountCount, baselineRecounts)
    }

    @MainActor
    func testRepeatedFailuresMoveChunkToFailedDirectory() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("service unavailable".utf8)
            )
        }

        let uploader = self.makeUploader(retryDelays: [0, 0, 0, 0])
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-2")
        let failureWindowStart = Date()

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("failed move") {
            uploader.failedCount == 1
        }

        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 5)
        XCTAssertTrue((uploader.lastError ?? "").contains("HTTP 503"))
        let failedAudio = self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("chunk-2.m4a")
        let failedSidecar = self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("chunk-2.json")
        let failedFailure = self.failureSidecarURL(sessionID: sessionID, chunkID: "chunk-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedSidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedFailure.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedFailure.appendingPathExtension("json").path))
        let failure = try self.decodeFailureSidecar(at: failedFailure)
        XCTAssertEqual(failure.httpStatus, 503)
        XCTAssertEqual(failure.attemptCount, 5)
        XCTAssertEqual(failure.stage, "http-failure")
        XCTAssertEqual(failure.sourceType, "observer-audio")
        XCTAssertTrue(failure.reason.contains("HTTP 503"))
        let lastAttemptAt = try XCTUnwrap(failure.lastAttemptAt)
        XCTAssertGreaterThanOrEqual(lastAttemptAt, failureWindowStart.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(lastAttemptAt, Date())
        XCTAssertEqual(uploader.failedCount, 1)
    }

    @MainActor
    func testCurrentPortTransportErrorMovesChunkToFailedDirectory() async throws {
        ObserverUploaderURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let uploader = self.makeUploader(maxAttempts: 1)
        let sessionID = UUID()
        let chunkID = "chunk-current-port-timeout"

        await uploader.enqueue(
            chunkURL: try self.makeChunkFile(named: chunkID),
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("current-port timeout failure") {
            uploader.failedCount == 1
        }
        XCTAssertEqual(uploader.pendingCount, 0)
        let failure = try self.decodeFailureSidecar(at: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID))
        XCTAssertEqual(failure.attemptCount, 1)
        XCTAssertEqual(failure.stage, "transport-failure")
    }

    @MainActor
    func testCancelledCompletionRequeuesWithoutConsumingAttempt() async throws {
        ObserverUploaderURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        let log = DiagnosticLog()
        let uploader = self.makeUploader(diagnosticLog: log, maxAttempts: 1)
        let sessionID = UUID()
        let chunkID = "chunk-cancelled-requeued"

        await uploader.enqueue(
            chunkURL: try self.makeChunkFile(named: chunkID),
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("cancelled completion requeued") {
            uploader.inFlightCount == 0
                && self.uploadEvents(in: log).contains { $0.message == "observer-audio upload reconnect-requeued" }
        }
        XCTAssertEqual(uploader.attemptCountForTesting(chunkID: chunkID), 0)
        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID).path))
    }

    @MainActor
    func testStalePortErrorRequeuesWithoutConsumingAttempt() async throws {
        let staleStarted = DispatchSemaphore(value: 0)
        let staleRelease = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.handler = { _ in
            staleStarted.signal()
            _ = staleRelease.wait(timeout: .now() + 2)
            throw URLError(.timedOut)
        }
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let log = DiagnosticLog()
        let uploader = self.makeUploader(
            localPortProvider: { localPort.withLock { $0 } },
            diagnosticLog: log,
            maxAttempts: 1
        )
        let sessionID = UUID()
        let chunkID = "chunk-stale-port-timeout"

        await uploader.enqueue(
            chunkURL: try self.makeChunkFile(named: chunkID),
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(staleStarted.wait(timeout: .now() + 2), .success)

        localPort.withLock { $0 = 9090 }
        staleRelease.signal()

        try await self.waitFor("stale-port completion requeued") {
            uploader.inFlightCount == 0
                && self.uploadEvents(in: log).contains { $0.message == "observer-audio upload reconnect-requeued" }
        }
        XCTAssertEqual(uploader.attemptCountForTesting(chunkID: chunkID), 0)
        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID).path))
    }

    @MainActor
    func testExhaustionAppliesDeltaWithoutFullRecount() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("service unavailable".utf8)
            )
        }

        let uploader = self.makeUploader(maxAttempts: 1)
        let baselineRecounts = uploader.fullRecountCount
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-exhaustion-delta")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("exhaustion delta") {
            uploader.pendingCount == 0 && uploader.failedCount == 1
        }
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 1)
        XCTAssertEqual(uploader.fullRecountCount, baselineRecounts)
    }

    @MainActor
    func testRetryScheduledDoesNotRefreshCounts() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("service unavailable".utf8)
            )
        }

        let uploader = self.makeUploader(
            maxAttempts: 2,
            sleep: { _ in try? await Task.sleep(for: .seconds(5)) }
        )
        let baselineRecounts = uploader.fullRecountCount
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-retry-scheduled")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("retry scheduled") {
            ObserverUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 1
        }
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(uploader.fullRecountCount, baselineRecounts)
        uploader.dropItem(sessionID: sessionID, chunkID: "chunk-retry-scheduled")
    }

    @MainActor
    func testInFlightCountTracksHeldUploadLifecycle() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.handler = { request in
            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader()
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-in-flight")

        XCTAssertEqual(uploader.inFlightCount, 0)
        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(uploader.inFlightCount, 1)

        uploadRelease.signal()
        try await self.waitFor("in-flight upload cleanup") {
            uploader.inFlightCount == 0 && uploader.pendingCount == 0 && uploader.lastUploadAt != nil
        }
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 1)
    }

    @MainActor
    func testJournalUnconfiguredLeavesPendingChunkWithoutAttemptsOrRetry() async throws {
        let sleepCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let registrationCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let uploader = self.makeUploader(
            ensureRegistered: {
                registrationCalls.withLock { $0 += 1 }
                throw ObserverUploaderError.registrationUnavailable
            },
            isJournalConfigured: { false },
            localPortProvider: { 7071 },
            sleep: { _ in sleepCalls.withLock { $0 += 1 } }
        )
        uploader.lastError = "stale"
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-unconfigured")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        await uploader.resumeFromDisk()
        await uploader.resumeFromDisk()

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(try self.directoryEntries(at: self.failedDirectoryURL(sessionID: sessionID)), [])
        XCTAssertNil(uploader.lastError)
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 0)
        XCTAssertEqual(registrationCalls.withLock { $0 }, 0)
        XCTAssertEqual(sleepCalls.withLock { $0 }, 0)
    }

    @MainActor
    func testHeldUploadsDoNotRefreshCounts() async throws {
        let journalHeldUploader = self.makeUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("held-journal", isDirectory: true),
            isJournalConfigured: { false }
        )
        let journalBaseline = journalHeldUploader.fullRecountCount
        let journalSessionID = UUID()
        await journalHeldUploader.enqueue(
            chunkURL: try self.makeChunkFile(named: "chunk-held-journal"),
            sidecar: self.makeSidecar(sessionID: journalSessionID, chunkIndex: 0)
        )
        XCTAssertEqual(journalHeldUploader.pendingCount, 1)
        XCTAssertEqual(journalHeldUploader.failedCount, 0)
        XCTAssertEqual(journalHeldUploader.fullRecountCount, journalBaseline)

        let noPortUploader = self.makeUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("held-port", isDirectory: true),
            localPortProvider: { nil }
        )
        let noPortBaseline = noPortUploader.fullRecountCount
        let noPortSessionID = UUID()
        await noPortUploader.enqueue(
            chunkURL: try self.makeChunkFile(named: "chunk-held-port"),
            sidecar: self.makeSidecar(sessionID: noPortSessionID, chunkIndex: 0)
        )
        XCTAssertEqual(noPortUploader.pendingCount, 1)
        XCTAssertEqual(noPortUploader.failedCount, 0)
        XCTAssertEqual(noPortUploader.fullRecountCount, noPortBaseline)
    }

    @MainActor
    func testNilPortHoldsThenFlushesWhenPortAppears() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let sleepCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let diagLog = DiagnosticLog()
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader(
            isJournalConfigured: { true },
            localPortProvider: { localPort.withLock { $0 } },
            diagnosticLog: diagLog,
            sleep: { _ in sleepCalls.withLock { $0 += 1 } }
        )
        uploader.lastError = "stale"
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-nil-port")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertNil(uploader.lastError)
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 0)
        XCTAssertEqual(sleepCalls.withLock { $0 }, 0)
        XCTAssertTrue(self.uploadEvents(in: diagLog).allSatisfy {
            $0.message != "observer-audio upload no-request-created"
        })

        localPort.withLock { $0 = 7071 }
        await uploader.resumeFromDisk()

        try await self.waitFor("nil-port observer flush") {
            uploader.pendingCount == 0 && ObserverUploaderURLProtocol.callCount == 1
        }
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertNil(uploader.lastError)
    }

    @MainActor
    func testReachabilitySatisfiedTriggersDrain() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        let uploader = self.makeUploader()
        let sessionID = UUID()
        let pendingAudio = self.pendingAudioURL(sessionID: sessionID, chunkID: "chunk-3")
        let pendingSidecar = self.pendingSidecarURL(sessionID: sessionID, chunkID: "chunk-3")
        try FileManager.default.createDirectory(at: pendingAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: pendingAudio)
        try self.makeEncoder().encode(self.makeSidecar(sessionID: sessionID, chunkIndex: 1)).write(to: pendingSidecar)

        uploader.handlePathStatus(.satisfied)

        try await self.waitFor("reachability drain") {
            ObserverUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 0
        }
    }

    @MainActor
    func testResumeFromDiskUploadsPendingChunk() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        let uploader = self.makeUploader()
        let sessionID = UUID()
        let pendingAudio = self.pendingAudioURL(sessionID: sessionID, chunkID: "chunk-4")
        let pendingSidecar = self.pendingSidecarURL(sessionID: sessionID, chunkID: "chunk-4")
        try FileManager.default.createDirectory(at: pendingAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: pendingAudio)
        try self.makeEncoder().encode(self.makeSidecar(sessionID: sessionID, chunkIndex: 2)).write(to: pendingSidecar)

        await uploader.resumeFromDisk()

        try await self.waitFor("resume drain") {
            ObserverUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 0
        }
    }

    @MainActor
    func testBackgroundCompletionHandlerIsInvoked() async throws {
        let uploader = self.makeUploader()
        let expectation = expectation(description: "background completion")

        uploader.handleBackgroundURLSessionEvents {
            expectation.fulfill()
        }
        uploader.finishBackgroundEvents()

        await fulfillment(of: [expectation], timeout: 1)
    }

    @MainActor
    func testDropItemRemovesLocalArtifactsAndDoesNotRegisterOrUpload() throws {
        let sessionID = UUID()
        let chunkID = "chunk-drop"
        let pendingAudio = self.pendingAudioURL(sessionID: sessionID, chunkID: chunkID)
        let pendingSidecar = self.pendingSidecarURL(sessionID: sessionID, chunkID: chunkID)
        let pendingUpload = pendingAudio.deletingLastPathComponent().appendingPathComponent("\(chunkID).upload")
        let failedAudio = self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).m4a")
        let failedSidecar = self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).json")
        let failedFailure = self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID)
        try FileManager.default.createDirectory(at: pendingAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failedAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: pendingAudio)
        try Data("sidecar".utf8).write(to: pendingSidecar)
        try Data("upload".utf8).write(to: pendingUpload)
        try Data("failed audio".utf8).write(to: failedAudio)
        try Data("failed sidecar".utf8).write(to: failedSidecar)
        try self.makeEncoder().encode(ObserverUploadFailureSidecar(
            reason: "failed",
            httpStatus: nil,
            transportError: nil,
            attemptCount: 5,
            stage: "transport-failure",
            sourceType: "observer-audio",
            lastAttemptAt: nil
        )).write(to: failedFailure)
        let uploader = self.makeUploader(ensureRegistered: {
            XCTFail("dropItem should not register")
            throw ObserverUploaderError.registrationUnavailable
        })

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 1)
        let baselineRecounts = uploader.fullRecountCount
        uploader.dropItem(sessionID: sessionID, chunkID: chunkID)

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(uploader.fullRecountCount, baselineRecounts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingSidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingUpload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedSidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedFailure.path))
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 0)
    }

    @MainActor
    func testDropItemCancelsInFlightUploadAndClearsBookkeeping() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.heldRequestPredicate = { request in
            request.url?.path == "/app/observer/ingest"
        }
        ObserverUploaderURLProtocol.onHeldRequest = { _ in
            uploadStarted.signal()
        }
        ObserverUploaderURLProtocol.handler = { request in
            XCTFail("held upload should not complete normally")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader()
        let sessionID = UUID()
        let chunkID = "chunk-cancel-drop"
        let sourceURL = try self.makeChunkFile(named: chunkID)

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.dropItem(sessionID: sessionID, chunkID: chunkID)

        try await self.waitFor("drop cancellation") {
            ObserverUploaderURLProtocol.stoppedRequests.contains { $0.url?.path == "/app/observer/ingest" }
        }
        XCTAssertFalse(uploader.hasInFlightTrackingForTesting(chunkID: chunkID))
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertNil(uploader.lastError)
    }

    @MainActor
    func testDropItemClearsInFlightStateSoLateCompletionIsHarmless() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.handler = { request in
            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("late failure".utf8)
            )
        }
        let uploader = self.makeUploader(retryDelays: [0])
        let sessionID = UUID()
        let chunkID = "chunk-in-flight"
        let sourceURL = try self.makeChunkFile(named: chunkID)

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.dropItem(sessionID: sessionID, chunkID: chunkID)
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertTrue(uploader.isDropTombstonedForTesting(chunkID: chunkID))
        uploadRelease.signal()

        try await self.waitFor("dropped completion ignored") {
            !uploader.isDropTombstonedForTesting(chunkID: chunkID)
        }

        XCTAssertNil(uploader.lastError)
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID).path))
        XCTAssertEqual(try self.directoryEntries(at: self.failedDirectoryURL(sessionID: sessionID)), [])
    }

    @MainActor
    func testDropTombstoneSuppressesLateSuccessfulCompletion() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.handler = { request in
            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let deliveredCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let uploader = self.makeUploader(onSegmentDelivered: { _ in
            deliveredCount.withLock { $0 += 1 }
        })
        let sessionID = UUID()
        let chunkID = "chunk-tombstone-success"
        let sourceURL = try self.makeChunkFile(named: chunkID)

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.plantDropTombstoneForTesting(chunkID: chunkID)
        uploadRelease.signal()

        try await self.waitFor("success tombstone eviction") {
            !uploader.isDropTombstonedForTesting(chunkID: chunkID)
        }

        XCTAssertEqual(deliveredCount.withLock { $0 }, 0)
        XCTAssertNil(uploader.lastUploadAt)
    }

    func testBackgroundSessionIdentifierInvariant() {
        XCTAssertEqual(ObserverUploader.backgroundSessionIdentifier, "app.solstone.swift.observer-upload")
    }

    @MainActor
    func testDefaultCacheRootInvariant() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverUploaderURLProtocol.self]
        _ = ObserverUploader(
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            localPortProvider: { 7071 },
            startPathMonitor: false
        )
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Observer", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testOmiSourceTypeYieldsOmiIDAndSourceLabel() throws {
        let uploader = self.makeUploader(sourceType: "omi-audio")
        let sessionID = UUID()
        let chunkID = "omi-chunk"
        try self.writeFailedPair(sessionID: sessionID, chunkID: chunkID)

        let items = try self.loadedItems(from: uploader.onThisPhoneSnapshot())

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "omi:\(sessionID.uuidString):\(chunkID)")
        XCTAssertEqual(item.sourceLabel, SourceVocabulary.onThisPhoneOmiAudioSourceLabel)
        XCTAssertEqual(item.retryAvailable, true)
    }

    @MainActor
    func testFailureSidecarSurvivesRelaunchAndPopulatesFailedItem() throws {
        let sessionID = UUID()
        let chunkID = "chunk-sidecar"
        let lastAttemptAt = Date(timeIntervalSince1970: 1_780_481_000)
        try self.writeFailedPair(
            sessionID: sessionID,
            chunkID: chunkID,
            failure: ObserverUploadFailureSidecar(
                reason: "journal rejected the upload (HTTP 503)",
                httpStatus: 503,
                transportError: nil,
                attemptCount: 5,
                stage: "http-failure",
                sourceType: "observer-audio",
                lastAttemptAt: lastAttemptAt
            )
        )

        let freshUploader = self.makeUploader()
        let items = try self.loadedItems(from: freshUploader.onThisPhoneSnapshot())

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "audio:\(sessionID.uuidString):\(chunkID)")
        XCTAssertEqual(item.failureReason, "journal rejected the upload (HTTP 503)")
        XCTAssertEqual(item.failureAttemptCount, 5)
        XCTAssertEqual(item.lastAttemptAt, lastAttemptAt)
        XCTAssertEqual(item.sourceLabel, SourceVocabulary.onThisPhoneObserverAudioSourceLabel)
        XCTAssertEqual(item.retryAvailable, true)
        XCTAssertEqual(item.sendState, .needsAttention)
    }

    @MainActor
    func testCorruptFailureSidecarDoesNotHideFailedAudioItem() throws {
        let sessionID = UUID()
        let chunkID = "chunk-corrupt"
        try self.writeFailedPair(sessionID: sessionID, chunkID: chunkID)
        try Data("{".utf8).write(to: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID), options: .atomic)
        let uploader = self.makeUploader()

        let items = try self.loadedItems(from: uploader.onThisPhoneSnapshot())

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "audio:\(sessionID.uuidString):\(chunkID)")
        XCTAssertNil(item.failureReason)
        XCTAssertNil(item.failureAttemptCount)
        XCTAssertNil(item.lastAttemptAt)
        XCTAssertEqual(item.retryAvailable, true)
    }

    func testFailureSidecarRoundTripsLastAttemptAt() throws {
        let lastAttemptAt = Date(timeIntervalSince1970: 1_780_481_000)
        let sidecar = ObserverUploadFailureSidecar(
            reason: "HTTP 503",
            httpStatus: 503,
            transportError: nil,
            attemptCount: 5,
            stage: "http-failure",
            sourceType: "observer-audio",
            lastAttemptAt: lastAttemptAt
        )
        let url = self.tempDirectory.appendingPathComponent("round-trip.failure", isDirectory: false)

        try self.makeEncoder().encode(sidecar).write(to: url)

        XCTAssertEqual(try self.decodeFailureSidecar(at: url), sidecar)
    }

    func testFailureSidecarMissingLastAttemptAtDecodesAsNil() throws {
        let url = self.tempDirectory.appendingPathComponent("missing-last-attempt.failure", isDirectory: false)
        try Data(
            #"{"attemptCount":5,"httpStatus":503,"reason":"HTTP 503","sourceType":"observer-audio","stage":"http-failure","transportError":null}"#.utf8
        ).write(to: url)

        let sidecar = try self.decodeFailureSidecar(at: url)

        XCTAssertEqual(sidecar.reason, "HTTP 503")
        XCTAssertEqual(sidecar.attemptCount, 5)
        XCTAssertNil(sidecar.lastAttemptAt)
    }

    @MainActor
    func testRequeueFailedItemMovesPairToPendingUploadsAndClearsFailure() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let sessionID = UUID()
        let chunkID = "chunk-requeue"
        try self.writeFailedPair(
            sessionID: sessionID,
            chunkID: chunkID,
            failure: ObserverUploadFailureSidecar(
                reason: "failed",
                httpStatus: nil,
                transportError: "network unavailable",
                attemptCount: 5,
                stage: "transport-failure",
                sourceType: "observer-audio",
                lastAttemptAt: nil
            )
        )
        let uploader = self.makeUploader()
        XCTAssertEqual(uploader.failedCount, 1)
        let baselineRecounts = uploader.fullRecountCount

        try await uploader.requeueFailedItem(sessionID: sessionID, chunkID: chunkID)

        try await self.waitFor("requeue upload") {
            ObserverUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 0 && uploader.failedCount == 0
        }
        XCTAssertEqual(uploader.fullRecountCount, baselineRecounts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID).path))
    }

    @MainActor
    func testRequeueFailedItemMissingPairThrowsAndLeavesFailed() async throws {
        let sessionID = UUID()
        let chunkID = "chunk-partial"
        let failedAudio = self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).m4a")
        try FileManager.default.createDirectory(at: failedAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: failedAudio)
        let uploader = self.makeUploader()

        do {
            try await uploader.requeueFailedItem(sessionID: sessionID, chunkID: chunkID)
            XCTFail("expected missing artifact error")
        } catch {
            // expected
        }

        XCTAssertEqual(uploader.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedAudio.path))
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 0)
    }

    @MainActor
    func testRequeueOverwriteFallsBackToFullRecount() async throws {
        let sessionID = UUID()
        let chunkID = "chunk-requeue-overwrite"
        try self.writeFailedPair(sessionID: sessionID, chunkID: chunkID)
        let pendingAudio = self.pendingAudioURL(sessionID: sessionID, chunkID: chunkID)
        try FileManager.default.createDirectory(at: pendingAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old pending audio".utf8).write(to: pendingAudio)
        let uploader = self.makeUploader(localPortProvider: { nil })
        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 1)
        let baselineRecounts = uploader.fullRecountCount

        try await uploader.requeueFailedItem(sessionID: sessionID, chunkID: chunkID)

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(uploader.fullRecountCount, baselineRecounts + 1)
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 0)
    }

    @MainActor
    func testEnqueueOverwriteFallsBackToFullRecount() async throws {
        let sessionID = UUID()
        let chunkID = "chunk-overwrite"
        let pendingAudio = self.pendingAudioURL(sessionID: sessionID, chunkID: chunkID)
        try FileManager.default.createDirectory(at: pendingAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old audio".utf8).write(to: pendingAudio)
        let uploader = self.makeUploader(localPortProvider: { nil })
        XCTAssertEqual(uploader.pendingCount, 1)
        let baselineRecounts = uploader.fullRecountCount

        await uploader.enqueue(
            chunkURL: try self.makeChunkFile(named: chunkID),
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(uploader.fullRecountCount, baselineRecounts + 1)
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 0)
    }

    @MainActor
    func testRetryFailedRequeuesCompletePairsAndSkipsIncompletePairs() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let sessionID = UUID()
        try self.writeFailedPair(sessionID: sessionID, chunkID: "chunk-complete")
        let partialAudio = self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("chunk-partial.m4a")
        try Data("audio".utf8).write(to: partialAudio)
        let uploader = self.makeUploader()
        XCTAssertEqual(uploader.failedCount, 2)

        await uploader.retryFailed()

        try await self.waitFor("retry failed upload") {
            ObserverUploaderURLProtocol.callCount == 1 && uploader.failedCount == 1
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialAudio.path))
    }

    @MainActor
    func testOmiAndWatchSourceTypesUseSameDeltaDrainPath() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        let omiUploader = self.makeUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("omi-delta", isDirectory: true),
            sourceType: "omi-audio"
        )
        let omiBaseline = omiUploader.fullRecountCount
        let omiSessionID = UUID()
        await omiUploader.enqueue(
            chunkURL: try self.makeChunkFile(named: "chunk-omi-delta"),
            sidecar: self.makeSidecar(sessionID: omiSessionID, chunkIndex: 0)
        )

        let watchUploader = self.makeUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("watch-delta", isDirectory: true),
            sourceType: "watch-audio"
        )
        let watchBaseline = watchUploader.fullRecountCount
        let watchSessionID = UUID()
        await watchUploader.enqueue(
            chunkURL: try self.makeChunkFile(named: "chunk-watch-delta"),
            sidecar: self.makeSidecar(sessionID: watchSessionID, chunkIndex: 0)
        )

        try await self.waitFor("omi/watch delta drain") {
            ObserverUploaderURLProtocol.callCount == 2
                && omiUploader.pendingCount == 0
                && watchUploader.pendingCount == 0
        }
        XCTAssertEqual(omiUploader.failedCount, 0)
        XCTAssertEqual(watchUploader.failedCount, 0)
        XCTAssertEqual(omiUploader.fullRecountCount, omiBaseline)
        XCTAssertEqual(watchUploader.fullRecountCount, watchBaseline)
    }

    @MainActor
    func testMigrateLegacySegmentKeysRewritesLegacyFailedSidecar() async throws {
        let uploader = self.makeUploader()
        let sessionID = UUID()
        let chunkID = "chunk-legacy"
        let startedAt = self.localStartedAt104355()
        try self.writeLegacyFailedChunk(
            sessionID: sessionID,
            chunkID: chunkID,
            segment: "20260623-104355",
            startedAt: startedAt,
            durationS: 300.0
        )

        let migratedCount = await uploader.migrateLegacySegmentKeys()

        XCTAssertEqual(migratedCount, 1)
        let migrated = try self.decodeSidecar(at: self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).json"))
        XCTAssertEqual(migrated.segment, "104355_300")
        XCTAssertNotNil(migrated.segment.wholeMatch(of: /^\d{6}_\d+$/))
        XCTAssertEqual(migrated.day, "20260623")
        XCTAssertEqual(migrated.chunkIndex, 0)
        XCTAssertEqual(migrated.startedAt, startedAt)
        XCTAssertEqual(migrated.durationS, 300.0)
        XCTAssertEqual(migrated.sessionID, sessionID)
        XCTAssertEqual(migrated.mode, .meeting)
    }

    @MainActor
    func testSegmentStringHelpersShareCanonicalImplementation() {
        let dates = [
            Date(timeIntervalSince1970: 1_782_216_235),
            self.localStartedAt104355(),
            Date(timeIntervalSince1970: 1_713_624_000),
        ]
        let durations = [300.0, 0.4, 47.6]

        for date in dates {
            for duration in durations {
                let canonical = ChunkSidecar.segmentString(for: date, durationSeconds: duration)
                XCTAssertEqual(ObserverManager.segmentString(for: date, durationSeconds: duration), canonical)
                XCTAssertEqual(OmiSegmentWriter.segmentString(for: date, durationSeconds: duration), canonical)
            }
        }
    }

    func testSegmentStringRoundsDurationWithMinimumOneSecond() {
        let date = Date(timeIntervalSince1970: 1_782_216_235)

        XCTAssertTrue(ChunkSidecar.segmentString(for: date, durationSeconds: 0.4).hasSuffix("_1"))
        XCTAssertTrue(ChunkSidecar.segmentString(for: date, durationSeconds: 47.6).hasSuffix("_48"))
    }

    @MainActor
    func testMigrateLegacySegmentKeysSkipsCanonicalSidecarIdempotently() async throws {
        let uploader = self.makeUploader()
        let sessionID = UUID()
        let chunkID = "chunk-canonical"
        try self.writeLegacyFailedChunk(
            sessionID: sessionID,
            chunkID: chunkID,
            segment: "104355_300",
            startedAt: self.localStartedAt104355(),
            durationS: 300.0
        )
        let sidecarURL = self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).json")
        let originalBytes = try Data(contentsOf: sidecarURL)

        let firstCount = await uploader.migrateLegacySegmentKeys()
        let firstBytes = try Data(contentsOf: sidecarURL)
        let secondCount = await uploader.migrateLegacySegmentKeys()
        let secondBytes = try Data(contentsOf: sidecarURL)

        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 0)
        XCTAssertEqual(firstBytes, originalBytes)
        XCTAssertEqual(secondBytes, originalBytes)
    }

    @MainActor
    func testMigrateLegacySegmentKeysReturnsZeroWithoutFailedDirectory() async {
        let uploader = self.makeUploader()

        let migratedCount = await uploader.migrateLegacySegmentKeys()

        XCTAssertEqual(migratedCount, 0)
    }

    @MainActor
    func testRetryFailedRequeuesMigratedLegacySidecar() async throws {
        let uploader = self.makeUploader(localPortProvider: { nil })
        let sessionID = UUID()
        let chunkID = "chunk-migrated-retry"
        try self.writeLegacyFailedChunk(
            sessionID: sessionID,
            chunkID: chunkID,
            segment: "20260623-104355",
            startedAt: self.localStartedAt104355(),
            durationS: 300.0
        )

        let migratedCount = await uploader.migrateLegacySegmentKeys()
        XCTAssertEqual(migratedCount, 1)
        await uploader.retryFailed()

        XCTAssertFalse(FileManager.default.fileExists(atPath: self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.pendingAudioURL(sessionID: sessionID, chunkID: chunkID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.pendingSidecarURL(sessionID: sessionID, chunkID: chunkID).path))
        let pendingSidecar = try self.decodeSidecar(at: self.pendingSidecarURL(sessionID: sessionID, chunkID: chunkID))
        XCTAssertEqual(pendingSidecar.segment, "104355_300")
    }

    @MainActor
    func testMultipartShapeInvariant() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        let uploader = self.makeUploader()
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-shape")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("multipart capture") {
            !ObserverUploaderURLProtocol.capturedBodies.isEmpty
        }

        let body = String(decoding: try XCTUnwrap(ObserverUploaderURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="segment""#))
        XCTAssertTrue(body.contains(#"name="day""#))
        XCTAssertTrue(body.contains(#"name="platform""#))
        XCTAssertTrue(body.contains(#"name="meta""#))
        XCTAssertTrue(body.contains(#"name="files"; filename="audio.m4a""#))
        XCTAssertFalse(body.contains("name=\"" + "files" + "[]\""))
        let metaHeader = try XCTUnwrap(body.range(of: #"Content-Disposition: form-data; name="meta""#))
        let afterMetaHeader = body[metaHeader.upperBound...]
        let separator = try XCTUnwrap(afterMetaHeader.range(of: "\r\n\r\n"))
        let metaStart = separator.upperBound
        let metaEnd = try XCTUnwrap(afterMetaHeader[metaStart...].range(of: "\r\n--")?.lowerBound)
        let meta = String(afterMetaHeader[metaStart..<metaEnd])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "segment",
            "day",
            "chunk_index",
            "started_at",
            "duration_s",
            "session_id",
            "mode",
        ])
    }

    @MainActor
    func testUploadDiagnosticsForNoRequestAndSuccessNeverLogSecret() async throws {
        let noPortLog = DiagnosticLog()
        let noPortUploader = self.makeUploader(
            localPortProvider: { nil },
            registrationPrefixProvider: { "obs_" },
            diagnosticLog: noPortLog
        )
        let noPortSessionID = UUID()
        let noPortSourceURL = try self.makeChunkFile(named: "chunk-no-port")

        await noPortUploader.enqueue(
            chunkURL: noPortSourceURL,
            sidecar: self.makeSidecar(sessionID: noPortSessionID, chunkIndex: 0)
        )

        XCTAssertTrue(self.uploadEvents(in: noPortLog).allSatisfy {
            $0.message != "observer-audio upload no-request-created"
        })
        noPortUploader.dropItem(sessionID: noPortSessionID, chunkID: "chunk-no-port")

        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let successLog = DiagnosticLog()
        let successUploader = self.makeUploader(
            localPortProvider: { 7071 },
            registrationPrefixProvider: { "obs_" },
            diagnosticLog: successLog
        )
        let successSessionID = UUID()
        let successSourceURL = try self.makeChunkFile(named: "chunk-success")

        await successUploader.enqueue(
            chunkURL: successSourceURL,
            sidecar: self.makeSidecar(sessionID: successSessionID, chunkIndex: 1)
        )

        try await self.waitFor("success diagnostics") {
            self.uploadEvents(in: successLog).contains { $0.message == "synced to your journal" }
        }
        let success = try XCTUnwrap(self.uploadEvents(in: successLog).first {
            $0.message == "synced to your journal"
        })
        XCTAssertEqual(success.severity, .info)
        XCTAssertTrue((success.detail ?? "").contains("localPort=7071"))
        XCTAssertTrue((success.detail ?? "").contains("httpStatus=200"))
        XCTAssertTrue((success.detail ?? "").contains("attempt=1/5"))

        for event in self.uploadEvents(in: noPortLog) + self.uploadEvents(in: successLog) {
            XCTAssertFalse(event.message.contains("test-observer-key-abc"))
            XCTAssertFalse((event.detail ?? "").contains("test-observer-key-abc"))
        }
    }

    @MainActor
    func testUploadDiagnosticsForTransportFailureRetryAndExhaustion() async throws {
        ObserverUploaderURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let log = DiagnosticLog()
        let uploader = self.makeUploader(
            retryDelays: [0],
            registrationPrefixProvider: { "obs_" },
            diagnosticLog: log,
            maxAttempts: 2
        )
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-transport")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("transport diagnostics") {
            uploader.failedCount == 1
        }

        let events = self.uploadEvents(in: log)
        XCTAssertTrue(events.contains { $0.message == "observer-audio upload transport-failure" && $0.severity == .warning })
        XCTAssertTrue(events.contains { $0.message == "observer-audio upload retry-scheduled" && $0.severity == .info })
        XCTAssertTrue(events.contains { $0.message == "observer-audio upload retry-exhausted" && $0.severity == .error })
        XCTAssertTrue(events.contains { ($0.detail ?? "").contains("transportError=") })
        for event in events {
            XCTAssertFalse(event.message.contains("test-observer-key-abc"))
            XCTAssertFalse((event.detail ?? "").contains("test-observer-key-abc"))
        }
    }

    @MainActor
    func testUploadDiagnosticsForHTTPFailureIncludeStatus() async throws {
        let visiblePrefix = String(repeating: "a", count: 200)
        let sensitiveTail = "SENSITIVE-TAIL"
        let longBody = visiblePrefix + sensitiveTail
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data(longBody.utf8)
            )
        }
        let log = DiagnosticLog()
        let uploader = self.makeUploader(
            registrationPrefixProvider: { "obs_" },
            diagnosticLog: log,
            maxAttempts: 1
        )
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-http")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("http diagnostics") {
            uploader.failedCount == 1
        }

        let events = self.uploadEvents(in: log)
        let httpFailure = try XCTUnwrap(events.first { $0.message == "observer-audio upload http-failure" })
        XCTAssertEqual(httpFailure.severity, .warning)
        let detail = httpFailure.detail ?? ""
        XCTAssertTrue(detail.contains("httpStatus=503"))
        XCTAssertTrue(detail.contains("reason=HTTP 503: \(visiblePrefix)"))
        XCTAssertFalse(detail.contains(sensitiveTail))
        XCTAssertTrue(events.contains { $0.message == "observer-audio upload retry-exhausted" && $0.severity == .error })

        let failure = try self.decodeFailureSidecar(at: self.failureSidecarURL(sessionID: sessionID, chunkID: "chunk-http"))
        XCTAssertEqual(failure.httpStatus, 503)
        XCTAssertTrue(failure.reason.contains("HTTP 503: \(visiblePrefix)"))
        XCTAssertFalse(failure.reason.contains(sensitiveTail))
        XCTAssertFalse(failure.reason.contains("test-observer-key-abc"))
    }

    @MainActor
    func testPersistedFailureReasonRedactsSecretsFromHTTPBodyPrefix() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("journal said no Authorization: Bearer persisted-secret-token".utf8)
            )
        }
        let log = DiagnosticLog()
        let uploader = self.makeUploader(diagnosticLog: log, maxAttempts: 1)
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-http-secret")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )

        try await self.waitFor("http secret failure") {
            uploader.failedCount == 1
        }

        let failure = try self.decodeFailureSidecar(
            at: self.failureSidecarURL(sessionID: sessionID, chunkID: "chunk-http-secret")
        )
        XCTAssertTrue(failure.reason.contains("journal said no Authorization: [redacted]"))
        XCTAssertFalse(failure.reason.contains("persisted-secret-token"))
        XCTAssertFalse(failure.reason.contains("Bearer persisted-secret-token"))
        XCTAssertFalse(failure.reason.contains("test-observer-key-abc"))
        XCTAssertFalse((uploader.lastError ?? "").contains("persisted-secret-token"))
        for event in self.uploadEvents(in: log) {
            XCTAssertFalse(event.message.contains("persisted-secret-token"))
            XCTAssertFalse((event.detail ?? "").contains("persisted-secret-token"))
            XCTAssertFalse((event.detail ?? "").contains("Bearer persisted-secret-token"))
        }
    }

    @MainActor
    func testStalePortReconcileCancelsOldTaskAndReschedulesOnCurrentPort() async throws {
        let staleStarted = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.heldRequestPredicate = { request in
            request.url?.port == 7071
        }
        ObserverUploaderURLProtocol.onHeldRequest = { _ in
            staleStarted.signal()
        }
        ObserverUploaderURLProtocol.handler = { request in
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let uploader = self.makeUploader(
            localPortProvider: { localPort.withLock { $0 } },
            registrationPrefixProvider: { "obs_" },
            urlBuilder: { localPort in
                URL(string: "http://127.0.0.1:\(localPort)/app/observer/ingest")
            }
        )
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-stale-port")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(staleStarted.wait(timeout: .now() + 2), .success)

        localPort.withLock { $0 = 9090 }
        await uploader.reconcilePortAndResume()

        try await self.waitFor("stale port reschedule") {
            ObserverUploaderURLProtocol.capturedRequests.contains { $0.url?.port == 9090 }
                && uploader.pendingCount == 0
        }
        try await self.waitFor("old task cancellation") {
            ObserverUploaderURLProtocol.stoppedRequests.contains { $0.url?.port == 7071 }
        }

        XCTAssertTrue(ObserverUploaderURLProtocol.capturedRequests.contains { $0.url?.port == 7071 })
        XCTAssertTrue(ObserverUploaderURLProtocol.capturedRequests.contains { $0.url?.port == 9090 })
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertFalse((uploader.lastError ?? "").contains("cancelled"))
    }

    @MainActor
    func testStaleCompletionDoesNotClobberRescheduledTask() async throws {
        let staleStarted = DispatchSemaphore(value: 0)
        let replacementStarted = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.heldRequestPredicate = { request in
            request.url?.port == 7071 || request.url?.port == 9090
        }
        ObserverUploaderURLProtocol.onHeldRequest = { request in
            switch request.url?.port {
            case 7071:
                staleStarted.signal()
            case 9090:
                replacementStarted.signal()
            default:
                break
            }
        }
        ObserverUploaderURLProtocol.handler = { request in
            XCTFail("held clobber-regression uploads should not complete normally")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let log = DiagnosticLog()
        let uploader = self.makeUploader(
            localPortProvider: { localPort.withLock { $0 } },
            registrationPrefixProvider: { "obs_" },
            urlBuilder: { localPort in
                URL(string: "http://127.0.0.1:\(localPort)/app/observer/ingest")
            },
            diagnosticLog: log,
            maxAttempts: 1
        )
        let sessionID = UUID()
        let chunkID = "chunk-stale-clobber"
        let requestBodyURL = self.sessionDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(chunkID).upload", isDirectory: false)

        await uploader.enqueue(
            chunkURL: try self.makeChunkFile(named: chunkID),
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(staleStarted.wait(timeout: .now() + 2), .success)

        localPort.withLock { $0 = 9090 }
        await uploader.reconcilePortAndResume()
        XCTAssertEqual(replacementStarted.wait(timeout: .now() + 2), .success)
        try await self.waitFor("stale completion did not clobber replacement") {
            self.uploadEvents(in: log).contains { $0.message == "observer-audio upload reconnect-requeued" }
        }
        XCTAssertEqual(uploader.attemptCountForTesting(chunkID: chunkID), 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertTrue(uploader.hasInFlightTrackingForTesting(chunkID: chunkID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestBodyURL.path))

        uploader.dropItem(sessionID: sessionID, chunkID: chunkID)
        try await self.waitFor("replacement cancellation") {
            ObserverUploaderURLProtocol.stoppedRequests.contains { $0.url?.port == 9090 }
        }
    }

    @MainActor
    func testReconcileRebuildsInFlightStateFromTaskDescription() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.handler = { request in
            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader(registrationPrefixProvider: { "obs_" })
        let sessionID = UUID()
        let sourceURL = try self.makeChunkFile(named: "chunk-relaunch")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.clearInMemoryUploadStateForTesting()
        await uploader.reconcilePortAndResume()
        uploadRelease.signal()

        try await self.waitFor("reconstructed completion") {
            uploader.pendingCount == 0 && uploader.lastUploadAt != nil
        }
        XCTAssertEqual(ObserverUploaderURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(uploader.failedCount, 0)
    }

    @MainActor
    func testRelaunchCompletionWithoutReconcileHonorsSuccess() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.handler = { request in
            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader(registrationPrefixProvider: { "obs_" })
        let sessionID = UUID()
        let chunkID = "chunk-relaunch-success"
        let sourceURL = try self.makeChunkFile(named: chunkID)

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.clearInMemoryUploadStateForTesting()
        uploadRelease.signal()

        try await self.waitFor("relaunch success completion") {
            uploader.pendingCount == 0 && uploader.lastUploadAt != nil
        }
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
    }

    @MainActor
    func testRelaunchCompletionWithoutReconcileHonorsFailure() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        ObserverUploaderURLProtocol.handler = { request in
            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("late failure".utf8)
            )
        }
        let uploader = self.makeUploader(
            retryDelays: [0],
            registrationPrefixProvider: { "obs_" },
            maxAttempts: 1
        )
        let sessionID = UUID()
        let chunkID = "chunk-relaunch-failure"
        let sourceURL = try self.makeChunkFile(named: chunkID)

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.clearInMemoryUploadStateForTesting()
        uploadRelease.signal()

        try await self.waitFor("relaunch failure completion") {
            uploader.failedCount == 1 && uploader.lastError != nil
        }
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 1)
        XCTAssertTrue((uploader.lastError ?? "").contains("HTTP 500"))
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID).path))
    }

    @MainActor private func makeUploader(
        cacheRootURL: URL? = nil,
        retryDelays: [UInt64] = [0],
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = { "test-observer-key-abc" },
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { 7071 },
        registrationPrefixProvider: @escaping @Sendable @MainActor () -> String? = { nil },
        urlBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            ObserverServerURL.ingestURL(localPort: localPort)
        },
        diagnosticLog: DiagnosticLog? = nil,
        onSegmentDelivered: (@MainActor @Sendable (UUID) -> Void)? = nil,
        sourceType: String = "observer-audio",
        maxAttempts: Int = 5,
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) -> ObserverUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverUploaderURLProtocol.self]
        return ObserverUploader(
            cacheRootURL: cacheRootURL ?? self.tempDirectory,
            sessionConfiguration: configuration,
            ensureRegistered: ensureRegistered,
            isJournalConfigured: isJournalConfigured,
            localPortProvider: localPortProvider,
            registrationPrefixProvider: registrationPrefixProvider,
            urlBuilder: urlBuilder,
            diagnosticLog: diagnosticLog,
            sourceType: sourceType,
            onSegmentDelivered: onSegmentDelivered,
            retryDelays: retryDelays,
            maxAttempts: maxAttempts,
            sleep: sleep,
            startPathMonitor: false
        )
    }

    private func makeChunkFile(named chunkID: String) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent("\(chunkID).m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func makeSidecar(sessionID: UUID, chunkIndex: Int) -> ChunkSidecar {
        ChunkSidecar(
            segment: "120000_3",
            day: "20260420",
            chunkIndex: chunkIndex,
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            durationS: 3,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func sessionDirectoryURL(sessionID: UUID) -> URL {
        self.tempDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func pendingAudioURL(sessionID: UUID, chunkID: String) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(chunkID).m4a", isDirectory: false)
    }

    private func pendingSidecarURL(sessionID: UUID, chunkID: String) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(chunkID).json", isDirectory: false)
    }

    private func writeFailedPair(
        sessionID: UUID,
        chunkID: String,
        failure: ObserverUploadFailureSidecar? = nil
    ) throws {
        let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: failedDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false))
        try self.makeEncoder().encode(self.makeSidecar(sessionID: sessionID, chunkIndex: 0))
            .write(to: failedDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        if let failure {
            try self.makeEncoder().encode(failure).write(to: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID))
        }
    }

    @MainActor private func writeLegacyFailedChunk(
        sessionID: UUID,
        chunkID: String,
        segment: String,
        startedAt: Date,
        durationS: TimeInterval
    ) throws {
        let dir = self.failedDirectoryURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.appendingPathComponent("\(chunkID).m4a", isDirectory: false))
        let sidecar = ChunkSidecar(
            segment: segment,
            day: "20260623",
            chunkIndex: 0,
            startedAt: startedAt,
            durationS: durationS,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
        try self.makeEncoder().encode(sidecar).write(to: dir.appendingPathComponent("\(chunkID).json", isDirectory: false))
    }

    private func failedDirectoryURL(sessionID: UUID) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("failed", isDirectory: true)
    }

    private func failureSidecarURL(sessionID: UUID, chunkID: String) -> URL {
        self.failedDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("\(chunkID).failure", isDirectory: false)
    }

    private func decodeFailureSidecar(at url: URL) throws -> ObserverUploadFailureSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ObserverUploadFailureSidecar.self, from: Data(contentsOf: url))
    }

    private func decodeSidecar(at url: URL) throws -> ChunkSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChunkSidecar.self, from: Data(contentsOf: url))
    }

    private func localStartedAt104355() -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 23
        comps.hour = 10
        comps.minute = 43
        comps.second = 55
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: comps)!
    }

    private func loadedItems(from result: OnThisPhoneSourceResult) throws -> [OnThisPhoneItem] {
        guard case .loaded(let items) = result else {
            XCTFail("Expected loaded result")
            return []
        }
        return items
    }

    private func directoryEntries(at directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    @MainActor private func uploadEvents(in log: DiagnosticLog) -> [DiagnosticEvent] {
        log.events.filter { $0.category == .upload }
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
}

private final class ObserverUploaderURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    typealias RequestPredicate = @Sendable (URLRequest) -> Bool
    typealias RequestObserver = @Sendable (URLRequest) -> Void

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let heldRequestPredicateBox = OSAllocatedUnfairLock<RequestPredicate?>(initialState: nil)
    private static let onHeldRequestBox = OSAllocatedUnfairLock<RequestObserver?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private static let capturedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
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
    static var callCount: Int {
        get { self.callCountBox.withLock { $0 } }
        set { self.callCountBox.withLock { $0 = newValue } }
    }
    static var capturedBodies: [Data] {
        get { self.bodiesBox.withLock { $0 } }
        set { self.bodiesBox.withLock { $0 = newValue } }
    }
    static var capturedRequests: [URLRequest] {
        get { self.capturedRequestsBox.withLock { $0 } }
        set { self.capturedRequestsBox.withLock { $0 = newValue } }
    }
    static var stoppedRequests: [URLRequest] {
        get { self.stoppedRequestsBox.withLock { $0 } }
        set { self.stoppedRequestsBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        XCTAssertEqual(self.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-observer-key-abc")
        Self.callCountBox.withLock { $0 += 1 }
        Self.capturedRequestsBox.withLock { $0.append(self.request) }
        let body = Self.bodyData(from: self.request)
        Self.bodiesBox.withLock { $0.append(body) }
        if Self.heldRequestPredicate?(self.request) == true {
            Self.onHeldRequest?(self.request)
            return
        }
        guard let handler = Self.handler else {
            XCTFail("ObserverUploaderURLProtocol handler not set")
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
        Self.stoppedRequestsBox.withLock { $0.append(self.request) }
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
