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

        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingAudioURL(sessionID: sessionID, chunkID: "chunk-1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.pendingSidecarURL(sessionID: sessionID, chunkID: "chunk-1").path))
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedSidecar.path))
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
    func testNilPortHoldsThenFlushesWhenPortAppears() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let sleepCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        ObserverUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader(
            isJournalConfigured: { true },
            localPortProvider: { localPort.withLock { $0 } },
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
        try FileManager.default.createDirectory(at: pendingAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failedAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: pendingAudio)
        try Data("sidecar".utf8).write(to: pendingSidecar)
        try Data("upload".utf8).write(to: pendingUpload)
        try Data("failed audio".utf8).write(to: failedAudio)
        try Data("failed sidecar".utf8).write(to: failedSidecar)
        let uploader = self.makeUploader(ensureRegistered: {
            XCTFail("dropItem should not register")
            throw ObserverUploaderError.registrationUnavailable
        })

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 1)
        uploader.dropItem(sessionID: sessionID, chunkID: chunkID)

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingSidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingUpload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedSidecar.path))
        XCTAssertEqual(ObserverUploaderURLProtocol.callCount, 0)
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
        let sourceURL = try self.makeChunkFile(named: "chunk-in-flight")

        await uploader.enqueue(
            chunkURL: sourceURL,
            sidecar: self.makeSidecar(sessionID: sessionID, chunkIndex: 0)
        )
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.dropItem(sessionID: sessionID, chunkID: "chunk-in-flight")
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        uploadRelease.signal()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(uploader.lastError)
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
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
        XCTAssertTrue(body.contains(#"name="files[]"; filename="audio.m4a""#))
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

        let noRequest = try XCTUnwrap(self.uploadEvents(in: noPortLog).first {
            $0.message == "observer-audio upload no-request-created"
        })
        XCTAssertEqual(noRequest.severity, .warning)
        XCTAssertTrue((noRequest.detail ?? "").contains("source=observer-audio"))
        XCTAssertTrue((noRequest.detail ?? "").contains("chunkID=chunk-no-port"))
        XCTAssertTrue((noRequest.detail ?? "").contains("prefix=obs_"))
        XCTAssertTrue((noRequest.detail ?? "").contains("localPort=none"))
        XCTAssertTrue((noRequest.detail ?? "").contains("attempt=0/5"))
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
            self.uploadEvents(in: successLog).contains { $0.message == "observer-audio upload success" }
        }
        let success = try XCTUnwrap(self.uploadEvents(in: successLog).first {
            $0.message == "observer-audio upload success"
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
            segment: "20260420-120000",
            day: "20260420",
            chunkIndex: chunkIndex,
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            durationS: 3,
            sessionID: sessionID,
            mode: .meeting
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

    private func failedDirectoryURL(sessionID: UUID) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("failed", isDirectory: true)
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
