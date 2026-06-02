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
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        ObserverUploaderURLProtocol.handler = nil
        ObserverUploaderURLProtocol.callCount = 0
        ObserverUploaderURLProtocol.capturedBodies = []
        super.tearDown()
    }

    @MainActor
    func testEnqueueUploadsAndCleansPendingFiles() async throws {
        ObserverUploaderURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/app/observer/ingest/test-observer-key-abc")
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

    @MainActor private func makeUploader(retryDelays: [UInt64] = [0]) -> ObserverUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverUploaderURLProtocol.self]
        return ObserverUploader(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            localPortProvider: { 7071 },
            retryDelays: retryDelays,
            sleep: { _ in },
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

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])
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
